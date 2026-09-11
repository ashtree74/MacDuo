// MacDuo — prototype of the iPhone Duo "lid closing" transition on a MacBook.
//
// 1. Reads the lid angle from the hidden HID sensor (Sensor page 0x20, usage 0x8A, feature report 1).
// 2. When the angle drops below a threshold, grabs a screenshot of the built-in display (ScreenCaptureKit).
// 3. Shows a full-screen overlay on the built-in display and, every frame, re-projects the screenshot
//    with a homography computed from the viewer's eye position, so the image appears to stay where the
//    screen *was* while the physical lid rotates through it. Progressive blur and a fade to black follow
//    the lid angle. Opening the lid reverses the effect and dismisses the overlay.
//
// This is NOT a 3D rotation of the screenshot. It is a planar central projection (homography) from the
// lid plane at the trigger angle onto the lid plane at the current angle, with the eye as the center.

import AppKit
import IOKit.hid
import ScreenCaptureKit
import QuartzCore
import CoreImage

// MARK: - Configuration

struct Config {
    static var startAngle: Double = 100     // effect starts below this lid angle (deg)
    static var fullAngle: Double = 25       // effect is "complete" at this angle (blur / fade fully applied)
    static var hysteresis: Double = 6       // lid must open this much above startAngle before the overlay dismisses
    static var eyeDistance: Double = 2.6    // eye distance from the screen center, in screen heights (16": H≈21.5 cm → ~56 cm)
    static var eyeHeight: Double = 0.5      // eye height above the screen center, along the screen, in screen heights
    static var projectionStrength: Double = 0.6 // scales δ fed into the homography: 1 = exact geometry, lower = gentler
    static var maxBlur: Double = 120        // maximum blur radius (points)
    static var maxDarken: Double = 1.0      // maximum darkening (1 = fades to full black at the far edge)
    static var smoothHz: Double = 4.5       // natural frequency of the spring filter (Hz): lower = smoother, more lag
    static var pollHz: Double = 120         // sensor polling rate
    static var demoSeconds: Double = 1.3    // closing/opening duration in the demo
    static var blurLevels = 5               // number of progressive blur layers (0 = no blur)
    static var trace = false                // log raw and smoothed angle every frame

    /// Settings adjustable from the status window, persisted across launches.
    static func load() {
        let d = UserDefaults.standard
        if d.object(forKey: "startAngle") != nil { startAngle = d.double(forKey: "startAngle") }
        if d.object(forKey: "projectionStrength") != nil { projectionStrength = d.double(forKey: "projectionStrength") }
        if d.object(forKey: "maxBlur") != nil { maxBlur = d.double(forKey: "maxBlur") }
        if d.object(forKey: "eyeHeight") != nil { eyeHeight = d.double(forKey: "eyeHeight") }
    }
    static func save() {
        let d = UserDefaults.standard
        d.set(startAngle, forKey: "startAngle")
        d.set(projectionStrength, forKey: "projectionStrength")
        d.set(maxBlur, forKey: "maxBlur")
        d.set(eyeHeight, forKey: "eyeHeight")
    }
}

let logFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
func log(_ s: String) {
    print("[\(logFormatter.string(from: Date()))] \(s)")
    fflush(stdout)
}

// MARK: - Lid angle sensor

final class LidAngleSensor {
    private let manager: IOHIDManager   // must outlive the device — otherwise getReport returns kIOReturnNotOpen
    private let device: IOHIDDevice
    private var buf = [UInt8](repeating: 0, count: 8)

    init?() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDPrimaryUsagePageKey: 0x20,   // Sensor
            kIOHIDPrimaryUsageKey: 0x8A,       // Orientation
        ]
        IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)
        let mo = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>
        log(String(format: "HID: managerOpen=0x%x, matching devices=%d", mo, set?.count ?? -1))
        guard let dev = set?.first else { return nil }
        let dO = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        log(String(format: "HID: deviceOpen=0x%x", dO))
        guard dO == kIOReturnSuccess else { return nil }
        manager = mgr
        device = dev
    }

    /// Angle in degrees: ~0 = closed, ~90 = upright, ~130 = fully open. Integer resolution.
    func read() -> Double? {
        var len = CFIndex(buf.count)
        let r = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &buf, &len)
        guard r == kIOReturnSuccess, len >= 3 else { log(String(format: "HID: getReport=0x%x len=%d", r, len)); return nil }
        return Double(UInt16(buf[2]) << 8 | UInt16(buf[1]))
    }
}

// MARK: - Screenshot

enum Screenshot {
    static func capture(display: CGDirectDisplayID, scale: CGFloat) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let d = content.displays.first(where: { $0.displayID == display }) else { return nil }
            let me = content.applications.filter { $0.processID == getpid() }
            let filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width = Int(CGFloat(d.width) * scale)
            cfg.height = Int(CGFloat(d.height) * scale)
            cfg.showsCursor = false
            cfg.captureResolution = .best
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        } catch {
            log("Screenshot failed: \(error)")
            return nil
        }
    }

    /// Fallback without Screen Recording permission: the desktop wallpaper.
    static func wallpaper(for screen: NSScreen) -> CGImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let img = NSImage(contentsOf: url) else { return nil }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

// MARK: - Overlay

final class FoldOverlay {
    let window: NSWindow
    private let root = CALayer()
    private let stage = CALayer()   // our own layer; AppKit repositions the anchorPoint of the view's backing layer
    private let plane = CALayer()
    private let sharp = CALayer()
    private var blurLevels: [(container: CALayer, fraction: Double)] = []
    private let darken = CAGradientLayer()
    private let hingeGlow = CAGradientLayer()
    private let size: CGSize

    /// Progressive blur levels: (fraction of the max radius, mask transition start/end in normalized height
    /// where 0 = hinge and 1 = far edge, rasterization scale). Higher levels sit on top of lower ones, so the far
    /// edge shows the largest radius while the hinge stays sharp. Rasterization scale < 1 keeps the blur cheap
    /// (blur erases the detail anyway).
    private static let levels: [(Double, Double, Double, CGFloat)] = [
        (0.08, 0.00, 0.25, 1.0),
        (0.20, 0.18, 0.45, 0.5),
        (0.42, 0.38, 0.65, 0.35),
        (0.70, 0.58, 0.85, 0.25),
        (1.00, 0.78, 1.00, 0.25),
    ]

    init(screen: NSScreen) {
        size = screen.frame.size
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = true
        window.backgroundColor = .black
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false

        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer = root
        window.contentView = view

        let W = size.width, H = size.height
        root.frame = CGRect(origin: .zero, size: size)
        root.backgroundColor = NSColor.black.cgColor

        // No perspective on the stage: the eye projection is computed exactly in the plane's homography.
        stage.frame = CGRect(origin: .zero, size: size)
        root.addSublayer(stage)

        // The "screen" plane — hinge on the bottom edge. No masksToBounds: the blur halo must bleed past the outline.
        plane.frame = CGRect(origin: .zero, size: size)
        plane.anchorPoint = CGPoint(x: 0.5, y: 0)
        plane.position = CGPoint(x: W / 2, y: 0)
        stage.addSublayer(plane)

        sharp.frame = plane.bounds
        sharp.contentsGravity = .resizeAspectFill
        plane.addSublayer(sharp)

        // Transparent margin around the image so the gaussian spreads the image edges outward.
        let pad = CGFloat(max(Config.maxBlur, 160)) * 2.5
        let padded = plane.bounds.insetBy(dx: -pad, dy: -pad)

        for (fraction, from, to, rasterScale) in Self.levels.prefix(Config.blurLevels) {
            let container = CALayer()
            container.frame = padded
            container.shouldRasterize = true
            container.rasterizationScale = rasterScale
            let img = CALayer()
            img.frame = CGRect(x: pad, y: pad, width: W, height: H)
            img.contentsGravity = .resizeAspectFill
            container.addSublayer(img)
            if let f = CIFilter(name: "CIGaussianBlur") {
                f.name = "blur"
                f.setValue(0, forKey: kCIInputRadiusKey)
                container.filters = [f]
            }
            let mask = CAGradientLayer()
            mask.frame = container.bounds
            mask.colors = [NSColor.clear.cgColor, NSColor.white.cgColor]
            // Mask in padded-layer coordinates: hinge at y = pad, far edge at y = pad + H.
            let y0 = (pad + CGFloat(from) * H) / padded.height
            let y1 = (pad + CGFloat(to) * H) / padded.height
            mask.startPoint = CGPoint(x: 0.5, y: y0)
            mask.endPoint = CGPoint(x: 0.5, y: y1)
            container.mask = mask
            container.opacity = 0
            plane.addSublayer(container)
            blurLevels.append((container, fraction))
        }

        // Fade to full black at the far edge (and in the halo above it), together with the blur.
        let hingeY = Double(pad / padded.height), farY = Double((pad + H) / padded.height)
        darken.frame = padded
        darken.colors = [NSColor.black.withAlphaComponent(0).cgColor,
                         NSColor.black.withAlphaComponent(0.2).cgColor,
                         NSColor.black.withAlphaComponent(0.7).cgColor,
                         NSColor.black.cgColor,
                         NSColor.black.cgColor]
        darken.locations = [NSNumber(value: hingeY), NSNumber(value: hingeY + (farY - hingeY) * 0.4),
                            NSNumber(value: hingeY + (farY - hingeY) * 0.75), NSNumber(value: farY), 1.0]
        darken.startPoint = CGPoint(x: 0.5, y: 0)
        darken.endPoint = CGPoint(x: 0.5, y: 1)
        darken.opacity = 0
        plane.addSublayer(darken)

        // Soft gradient at the hinge — the "softness" seen on the Duo.
        hingeGlow.frame = CGRect(x: 0, y: 0, width: W, height: H * 0.12)
        hingeGlow.colors = [NSColor.black.withAlphaComponent(0.7).cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        hingeGlow.startPoint = CGPoint(x: 0.5, y: 0)
        hingeGlow.endPoint = CGPoint(x: 0.5, y: 1)
        hingeGlow.opacity = 0
        stage.addSublayer(hingeGlow)
    }

    /// Half-resolution copy for the blurred layers (less memory to chew through every frame).
    private static func downsample(_ img: CGImage, by factor: Int) -> CGImage {
        let w = img.width / factor, h = img.height / factor
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return img }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    func show(image: CGImage) {
        let small = Self.downsample(image, by: 2)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        sharp.contents = image
        for level in blurLevels { level.container.sublayers?.first?.contents = small }
        apply(progress: 0, delta: 0)
        CATransaction.commit()
        window.orderFrontRegardless()
    }

    func hide() { window.orderOut(nil) }
    var isVisible: Bool { window.isVisible }

    /// "The screen stayed where it was" homography: central projection from the viewer's eye, from the lid plane
    /// at the trigger angle (θ0) onto the lid plane at the current angle (θ0 − δ). Plane-local coordinates:
    /// x from the center, y from the hinge (anchorPoint 0.5/0).
    ///
    ///   x1 = K·x0 / (K − b·y0),  y1 = c·y0 / (K − b·y0)
    ///   b = sin δ,  c = −D,  K = b·(H/2 + e) − D·cos δ     (D = eye distance, e = eye height above the center)
    ///
    /// δ = 0 yields the identity; the hinge (y0 = 0) always maps to the hinge.
    static func homography(delta: Double, H: Double, eyeDistance D: Double, eyeHeight e: Double) -> CATransform3D {
        // Beyond this angle the rays to the lowest rows become parallel to the lid (denominator → 0).
        let limit = 0.92 * atan(D / (H / 2 + e + H * 0.3))
        let d = min(max(delta, 0), limit)
        let b = sin(d), c = -D
        let K = b * (H / 2 + e) - D * cos(d)
        // CA row-vector convention: x' = x·m11 + y·m21 + m41, w' = x·m14 + y·m24 + m44.
        // Negated so that w' > 0 (K < 0 for sane δ) — CA culls points "behind the camera".
        var m = CATransform3DIdentity
        m.m11 = -K
        m.m22 = -c
        m.m24 = b
        m.m33 = 1
        m.m44 = -K
        return m
    }

    /// progress 0 = flat/sharp, 1 = fully folded; delta = angle (rad) the lid has moved from the trigger position.
    func apply(progress p: Double, delta: Double) {
        let p = min(max(p, 0), 1)
        let e = p * p * (3 - 2 * p)   // soft start
        let H = Double(size.height)
        let t = Self.homography(delta: delta * Config.projectionStrength, H: H, eyeDistance: Config.eyeDistance * H, eyeHeight: Config.eyeHeight * H)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        plane.transform = t
        for level in blurLevels {
            level.container.setValue(Config.maxBlur * level.fraction * e, forKeyPath: "filters.blur.inputRadius")
            level.container.opacity = Float(min(1, e * 2.5))
        }
        darken.opacity = Float(min(1, e * 2) * Config.maxDarken)
        hingeGlow.opacity = Float(min(1, e * 3))
        CATransaction.commit()
    }
}

// MARK: - Status window

/// Side profile of the laptop with a live lid angle, drawn with NSBezierPath.
final class LidGaugeView: NSView {
    var angle: Double = 108 { didSet { needsDisplay = true } }
    var triggerAngle: Double = 100 { didSet { needsDisplay = true } }
    var active = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 200, height: 150) }

    override func draw(_ dirtyRect: NSRect) {
        let hinge = NSPoint(x: bounds.midX - 50, y: 34)
        let baseLen: CGFloat = 118, lidLen: CGFloat = 104
        let accent = NSColor(red: 0.42, green: 0.66, blue: 1.0, alpha: 1)

        // Base (keyboard deck).
        let base = NSBezierPath()
        base.lineWidth = 7; base.lineCapStyle = .round
        base.move(to: hinge); base.line(to: NSPoint(x: hinge.x + baseLen, y: hinge.y))
        NSColor.white.withAlphaComponent(0.85).setStroke(); base.stroke()

        // Trigger marker: thin dashed lid at the trigger angle.
        let ta = CGFloat(triggerAngle) * .pi / 180
        let marker = NSBezierPath()
        marker.lineWidth = 1.5
        marker.setLineDash([3, 4], count: 2, phase: 0)
        marker.move(to: hinge)
        marker.line(to: NSPoint(x: hinge.x + cos(ta) * lidLen, y: hinge.y + sin(ta) * lidLen))
        NSColor.systemOrange.withAlphaComponent(0.8).setStroke(); marker.stroke()

        // Angle arc.
        let arc = NSBezierPath()
        arc.lineWidth = 3
        arc.appendArc(withCenter: hinge, radius: 34, startAngle: 0, endAngle: CGFloat(angle), clockwise: false)
        (active ? NSColor.systemOrange : accent).withAlphaComponent(0.9).setStroke(); arc.stroke()

        // Lid with a glow along the screen face.
        let a = CGFloat(angle) * .pi / 180
        let tip = NSPoint(x: hinge.x + cos(a) * lidLen, y: hinge.y + sin(a) * lidLen)
        let glow = NSBezierPath()
        glow.lineWidth = 16; glow.lineCapStyle = .round
        glow.move(to: hinge); glow.line(to: tip)
        (active ? NSColor.systemOrange : accent).withAlphaComponent(0.22).setStroke(); glow.stroke()
        let lid = NSBezierPath()
        lid.lineWidth = 7; lid.lineCapStyle = .round
        lid.move(to: hinge); lid.line(to: tip)
        NSColor.white.setStroke(); lid.stroke()

        // Hinge dot.
        let dot = NSBezierPath(ovalIn: NSRect(x: hinge.x - 5, y: hinge.y - 5, width: 10, height: 10))
        NSColor.black.setFill(); dot.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke(); dot.lineWidth = 2; dot.stroke()
    }
}

/// Startup window: dark, glassy, with a live lid gauge, the three checks the effect needs, and tuning sliders.
final class StatusWindow {
    let window: NSWindow
    private let gauge = LidGaugeView()
    private let angleLabel = NSTextField(labelWithString: "—")
    private let angleCaption = NSTextField(labelWithString: "")
    private var checkIcons: [NSImageView] = []
    private var checkLabels: [NSTextField] = []
    private let fixButton = NSButton(title: "Grant access…", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let startSlider = NSSlider(value: Config.startAngle, minValue: 60, maxValue: 125, target: nil, action: nil)
    private let strengthSlider = NSSlider(value: Config.projectionStrength, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let blurSlider = NSSlider(value: Config.maxBlur, minValue: 0, maxValue: 160, target: nil, action: nil)
    private let eyeSlider = NSSlider(value: Config.eyeHeight, minValue: -0.5, maxValue: 1.5, target: nil, action: nil)
    private var valueLabels: [NSSlider: NSTextField] = [:]
    var onSettingsChanged: (() -> Void)?

    init(demoAction: Selector, target: AnyObject) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "MacDuo"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.center()

        // Background: vibrancy + deep gradient + a soft radial glow behind the gauge.
        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        let tint = CAGradientLayer()
        tint.colors = [NSColor(red: 0.04, green: 0.06, blue: 0.14, alpha: 0.92).cgColor,
                       NSColor(red: 0.01, green: 0.01, blue: 0.03, alpha: 0.96).cgColor]
        tint.startPoint = CGPoint(x: 0.2, y: 1); tint.endPoint = CGPoint(x: 0.8, y: 0)
        tint.frame = NSRect(x: 0, y: 0, width: 480, height: 640)
        tint.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        backdrop.layer?.addSublayer(tint)
        let glow = CAGradientLayer()
        glow.type = .radial
        glow.colors = [NSColor(red: 0.3, green: 0.5, blue: 1.0, alpha: 0.28).cgColor, NSColor.clear.cgColor]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5); glow.endPoint = CGPoint(x: 1, y: 1)
        glow.frame = NSRect(x: -60, y: 300, width: 380, height: 380)
        backdrop.layer?.addSublayer(glow)
        window.contentView = backdrop

        // Header.
        let title = NSTextField(labelWithString: "MacDuo")
        title.font = .systemFont(ofSize: 34, weight: .heavy)
        title.textColor = .white
        let subtitle = NSTextField(wrappingLabelWithString: "iPhone Duo's lid-closing transition, driven live by your MacBook's lid angle sensor.")
        subtitle.textColor = NSColor.white.withAlphaComponent(0.6)
        subtitle.font = .systemFont(ofSize: 13)

        // Gauge card.
        angleLabel.font = .monospacedDigitSystemFont(ofSize: 44, weight: .bold)
        angleLabel.textColor = .white
        angleCaption.font = .systemFont(ofSize: 12, weight: .medium)
        angleCaption.textColor = NSColor.white.withAlphaComponent(0.55)
        let angleStack = NSStackView(views: [angleLabel, angleCaption])
        angleStack.orientation = .vertical; angleStack.alignment = .leading; angleStack.spacing = 2
        let gaugeRow = NSStackView(views: [gauge, angleStack])
        gaugeRow.orientation = .horizontal; gaugeRow.spacing = 8; gaugeRow.alignment = .centerY
        let gaugeCard = Self.card(gaugeRow)

        // Checks card.
        var checkRows: [NSView] = []
        for _ in 0..<3 {
            let icon = NSImageView()
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = NSColor.white.withAlphaComponent(0.9)
            label.lineBreakMode = .byTruncatingTail
            let row = NSStackView(views: [icon, label])
            row.orientation = .horizontal; row.spacing = 10
            checkIcons.append(icon); checkLabels.append(label); checkRows.append(row)
        }
        fixButton.target = target
        fixButton.action = #selector(Controller.openScreenRecordingSettings)
        fixButton.bezelStyle = .rounded
        fixButton.controlSize = .small
        let fixRow = NSStackView(views: [NSView(), fixButton])
        fixRow.orientation = .horizontal
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor.white.withAlphaComponent(0.5)
        let checksStack = NSStackView(views: checkRows + [hint, fixRow])
        checksStack.orientation = .vertical; checksStack.alignment = .leading; checksStack.spacing = 9
        checksStack.setCustomSpacing(4, after: hint)
        let checksCard = Self.card(checksStack)

        // Tuning card.
        let tuningTitle = NSTextField(labelWithString: "TUNING")
        tuningTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        tuningTitle.textColor = NSColor.white.withAlphaComponent(0.45)
        let rows: [NSView] = [
            tuningTitle,
            sliderRow("Trigger angle", startSlider, target: target),
            sliderRow("Projection strength", strengthSlider, target: target),
            sliderRow("Blur", blurSlider, target: target),
            sliderRow("Eye height", eyeSlider, target: target),
        ]
        let tuningStack = NSStackView(views: rows)
        tuningStack.orientation = .vertical; tuningStack.alignment = .leading; tuningStack.spacing = 10
        let tuningCard = Self.card(tuningStack)

        // Footer.
        let demoButton = NSButton(title: "Run demo", target: target, action: demoAction)
        demoButton.bezelStyle = .rounded
        demoButton.controlSize = .large
        demoButton.keyEquivalent = "\r"
        let hideButton = NSButton(title: "Hide", target: window, action: #selector(NSWindow.orderOut(_:)))
        hideButton.bezelStyle = .rounded
        hideButton.controlSize = .large
        let footer = NSStackView(views: [NSView(), hideButton, demoButton])
        footer.orientation = .horizontal; footer.spacing = 10

        let stack = NSStackView(views: [title, subtitle, gaugeCard, checksCard, tuningCard, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 44, left: 24, bottom: 22, right: 24)
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(20, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            stack.topAnchor.constraint(equalTo: backdrop.topAnchor),
            stack.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        for v in [subtitle, gaugeCard, checksCard, tuningCard, footer] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
        for v in [gaugeRow, checksStack, tuningStack] as [NSView] {
            v.widthAnchor.constraint(equalTo: v.superview!.widthAnchor, constant: -32).isActive = true
        }
        fixRow.widthAnchor.constraint(equalTo: checksStack.widthAnchor).isActive = true
        hint.widthAnchor.constraint(equalTo: checksStack.widthAnchor).isActive = true
        for r in rows.dropFirst() { r.widthAnchor.constraint(equalTo: tuningStack.widthAnchor).isActive = true }
        refreshValues()
    }

    /// Rounded translucent card around a content view.
    private static func card(_ content: NSView) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        card.layer?.borderWidth = 1
        card.layer?.cornerRadius = 16
        card.layer?.cornerCurve = .continuous
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])
        return card
    }

    private func sliderRow(_ name: String, _ slider: NSSlider, target: AnyObject) -> NSView {
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 128).isActive = true
        let value = NSTextField(labelWithString: "")
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        value.textColor = NSColor.white.withAlphaComponent(0.6)
        value.alignment = .right
        value.translatesAutoresizingMaskIntoConstraints = false
        value.widthAnchor.constraint(equalToConstant: 52).isActive = true
        slider.isContinuous = true
        slider.target = target
        slider.action = #selector(Controller.settingChanged(_:))
        valueLabels[slider] = value
        let row = NSStackView(views: [label, slider, value])
        row.orientation = .horizontal; row.spacing = 10
        return row
    }

    var sliders: (start: NSSlider, strength: NSSlider, blur: NSSlider, eye: NSSlider) {
        (startSlider, strengthSlider, blurSlider, eyeSlider)
    }

    func refreshValues() {
        valueLabels[startSlider]?.stringValue = String(format: "%.0f°", startSlider.doubleValue)
        valueLabels[strengthSlider]?.stringValue = String(format: "%.0f %%", strengthSlider.doubleValue * 100)
        valueLabels[blurSlider]?.stringValue = String(format: "%.0f pt", blurSlider.doubleValue)
        valueLabels[eyeSlider]?.stringValue = String(format: "%+.1f H", eyeSlider.doubleValue)
        gauge.triggerAngle = startSlider.doubleValue
    }

    func update(sensorOK: Bool, captureOK: Bool, displayName: String?, angle: Double, simulated: Bool, active: Bool) {
        gauge.angle = angle
        gauge.active = active
        angleLabel.stringValue = String(format: "%.0f°", angle)
        angleCaption.stringValue = active ? "folding — effect live" : (simulated ? "lid angle (simulated)" : "lid angle · trigger at \(Int(Config.startAngle))°")

        let checks: [(Bool, String, String)] = [
            (sensorOK, "Lid angle sensor", "Lid angle sensor not found — demo and slider only"),
            (captureOK, "Screen Recording permission", "Screen Recording permission missing — wallpaper will be used"),
            (displayName != nil, "Built-in display: \(displayName ?? "")", "No built-in display found"),
        ]
        for (i, (ok, good, bad)) in checks.enumerated() {
            checkIcons[i].image = NSImage(systemSymbolName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", accessibilityDescription: nil)
            checkIcons[i].contentTintColor = ok ? NSColor(red: 0.3, green: 0.85, blue: 0.5, alpha: 1) : .systemOrange
            checkLabels[i].stringValue = ok ? good : bad
        }
        fixButton.isHidden = captureOK
        hint.stringValue = captureOK
            ? "All set. MacDuo lives in the menu bar (∠). Close the lid to see the effect, or run the demo."
            : "System Settings → Privacy & Security → Screen Recording. MacDuo relaunches itself once access is granted."
    }
}

// MARK: - Controller

final class Controller: NSObject, NSApplicationDelegate {
    private var sensor: LidAngleSensor?
    private var statusItem: NSStatusItem!
    private var overlay: FoldOverlay?
    private var statusWindow: StatusWindow?
    private var screen: NSScreen!
    private var displayID: CGDirectDisplayID = 0

    private var rawAngle: Double = 120
    @objc dynamic var simAngle: NSNumber? = nil  // when set, replaces the sensor (KVC for --hold)
    private var lastAngle: Double = 120
    private var smoothAngle: Double = 120      // spring filter output
    private var smoothVelocity: Double = 0     // deg/s
    private var displayedProgress: Double = 0
    private var displayLink: CADisplayLink?
    private var frameCount = 0
    private var maxFrameDt = 0.0
    private var applyTime = 0.0
    private var readTime = 0.0
    private var readCount = 0
    private var activeSince = CACurrentMediaTime()
    private var lastFrame = CACurrentMediaTime()
    private var capturing = false
    private var active = false
    private var simPanel: NSPanel?
    private var demoTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Config.load()
        applyCommandLineOverrides()
        // The built-in display (the lid) — never an external screen.
        screen = NSScreen.screens.first { s in
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return CGDisplayIsBuiltin(id) != 0
        } ?? NSScreen.main!
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        for s in NSScreen.screens {
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            log(String(format: "Display: %@ id=%u %@ %.0fx%.0f @%.0f,%.0f%@", s.localizedName, id, CGDisplayIsBuiltin(id) != 0 ? "[built-in]" : "[external]",
                       s.frame.width, s.frame.height, s.frame.origin.x, s.frame.origin.y, id == displayID ? "  <- used for the effect and the screenshot" : ""))
        }
        overlay = FoldOverlay(screen: screen)

        sensor = LidAngleSensor()
        if let s = sensor, let a = s.read() { rawAngle = a; lastAngle = a; smoothAngle = a; log("Sensor OK, angle = \(a)°") }
        else { log("No lid angle sensor — only the demo and the slider are available.") }

        setupMenu()
        ensureScreenCapturePermission()

        statusWindow = StatusWindow(demoAction: #selector(runDemo), target: self)
        if !CommandLine.arguments.contains("--no-window") { showStatusWindow() }
        let statusTimer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.refreshStatusWindow() }
        RunLoop.main.add(statusTimer, forMode: .common)

        let t = Timer(timeInterval: 1.0 / Config.pollHz, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)

        // Rendering in sync with the built-in display's refresh (120 Hz on ProMotion).
        let link = screen.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastFrame = CACurrentMediaTime()
    }

    // MARK: Status window

    private var builtInDisplayFound: Bool {
        CGDisplayIsBuiltin(displayID) != 0
    }

    private func refreshStatusWindow() {
        guard let statusWindow, statusWindow.window.isVisible else { return }
        statusWindow.update(sensorOK: sensor != nil,
                            captureOK: CGPreflightScreenCaptureAccess(),
                            displayName: builtInDisplayFound ? screen.localizedName : nil,
                            angle: rawAngle, simulated: simAngle != nil, active: active)
    }

    @objc func showStatusWindow() {
        refreshStatusWindow()
        statusWindow?.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshStatusWindow()
    }

    @objc func settingChanged(_ sender: NSSlider) {
        guard let sw = statusWindow else { return }
        Config.startAngle = sw.sliders.start.doubleValue.rounded()
        Config.projectionStrength = sw.sliders.strength.doubleValue
        Config.maxBlur = sw.sliders.blur.doubleValue
        Config.eyeHeight = sw.sliders.eye.doubleValue
        Config.save()
        sw.refreshValues()
    }

    @objc func openScreenRecordingSettings() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Screen Recording permission

    /// Without Screen Recording the screenshot fails (the wallpaper is used instead). Ask right at launch, and once
    /// the user grants it in System Settings, relaunch ourselves (macOS requires a relaunch for this permission).
    private func ensureScreenCapturePermission() {
        if CGPreflightScreenCaptureAccess() { log("Screen Recording: permission granted."); return }
        log("Screen Recording: no permission — requesting it (System Settings → Privacy & Security → Screen Recording).")
        CGRequestScreenCaptureAccess()
        let t = Timer(timeInterval: 2, repeats: true) { t in
            guard CGPreflightScreenCaptureAccess() else { return }
            t.invalidate()
            log("Permission granted — relaunching.")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-n", Bundle.main.bundleURL.path]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                try? proc.run()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    // MARK: Sensor loop

    private var lastSourceWasSim = false
    private func tick() {
        let usingSim = simAngle != nil
        if let sim = simAngle { rawAngle = sim.doubleValue }
        else if let sensor {
            let t0 = CACurrentMediaTime()
            if let a = sensor.read() { rawAngle = a }
            readTime += CACurrentMediaTime() - t0; readCount += 1
        }

        let angle = rawAngle
        defer { lastAngle = angle; updateStatus() }

        // Switching the source (demo/slider <-> sensor) is a value jump, not lid motion: don't trigger, resync the filter.
        if usingSim != lastSourceWasSim {
            lastSourceWasSim = usingSim
            if !active { smoothAngle = angle; smoothVelocity = 0 }
            return
        }

        // Trigger: the raw reading crosses the threshold downward (raw, so no filter lag).
        if !active, !capturing, lastAngle >= Config.startAngle, angle < Config.startAngle {
            trigger()
        }
    }

    /// Critically damped spring filter: smooths the sensor's 1° steps, and during continuous motion keeps the
    /// velocity, so the lag is small (~2/ω) and constant.
    private func smooth(dt: Double) {
        let omega = 2 * .pi * Config.smoothHz
        let steps = max(1, Int(ceil(dt / 0.002)))          // sub-steps for stability with large dt
        let h = dt / Double(steps)
        for _ in 0..<steps {
            let accel = omega * omega * (rawAngle - smoothAngle) - 2 * omega * smoothVelocity
            smoothVelocity += accel * h
            smoothAngle += smoothVelocity * h
        }
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastFrame, 0.001), 0.1)
        lastFrame = now
        smooth(dt: dt)
        if Config.trace, active { log(String(format: "raw=%.0f smooth=%.2f v=%.1f", rawAngle, smoothAngle, smoothVelocity)) }

        guard active, let overlay else { return }
        frameCount += 1
        maxFrameDt = max(maxFrameDt, dt)

        // Target: 0 at startAngle, 1 at fullAngle (linear in the smoothed lid angle).
        let span = Config.startAngle - Config.fullAngle
        var target = (Config.startAngle - smoothAngle) / span
        let releasing = rawAngle > Config.startAngle + Config.hysteresis
        if releasing { target = 0 }
        displayedProgress = min(max(target, 0), 1)
        let delta = releasing ? 0 : max(0, Config.startAngle - smoothAngle) * .pi / 180
        let t0 = CACurrentMediaTime()
        overlay.apply(progress: displayedProgress, delta: delta)
        applyTime += CACurrentMediaTime() - t0

        if releasing, displayedProgress < 0.004 {
            active = false
            displayedProgress = 0
            overlay.hide()
            let secs = CACurrentMediaTime() - activeSince
            log(String(format: "Lid opened — overlay hidden. %d frames in %.1f s = %.0f fps, longest frame %.0f ms; apply avg %.2f ms/frame; HID read avg %.2f ms (%d reads); menu bar title avg %.2f ms (%d changes).",
                       frameCount, secs, Double(frameCount) / secs, maxFrameDt * 1000,
                       applyTime / Double(max(frameCount, 1)) * 1000, readTime / Double(max(readCount, 1)) * 1000, readCount,
                       statusTime / Double(max(statusCount, 1)) * 1000, statusCount))
        }
    }

    private func trigger() {
        capturing = true
        log("Threshold \(Config.startAngle)° crossed (angle \(rawAngle)°) — taking a screenshot…")
        let scale = screen.backingScaleFactor
        let id = displayID
        let t0 = CACurrentMediaTime()
        Task { @MainActor in
            var img = await Screenshot.capture(display: id, scale: scale)
            var source = "ScreenCaptureKit"
            if img == nil { img = Screenshot.wallpaper(for: self.screen); source = "wallpaper (fallback)" }
            self.capturing = false
            guard let img, self.rawAngle < Config.startAngle + Config.hysteresis else {
                log("Cancelled (no image, or the lid is open again).")
                return
            }
            log(String(format: "Screenshot ready in %.0f ms (%@, %dx%d) — starting the effect.", (CACurrentMediaTime() - t0) * 1000, source, img.width, img.height))
            self.displayedProgress = 0
            self.frameCount = 0
            self.maxFrameDt = 0
            self.applyTime = 0; self.readTime = 0; self.readCount = 0; self.statusTime = 0; self.statusCount = 0
            self.activeSince = CACurrentMediaTime()
            self.active = true
            self.overlay?.show(image: img)
        }
    }

    // MARK: Menu / simulation

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(withTitle: "Status & permissions…", action: #selector(showStatusWindow), keyEquivalent: "i")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Demo: close and open (simulated)", action: #selector(runDemo), keyEquivalent: "d")
        menu.addItem(withTitle: "Angle simulation slider…", action: #selector(showSimPanel), keyEquivalent: "s")
        menu.addItem(withTitle: "Back to the real sensor", action: #selector(useSensor), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        updateStatus()
    }

    private var lastTitle = ""
    private var lastTitleTime = 0.0
    private var statusTime = 0.0
    private var statusCount = 0
    /// Changing the menu bar title is a synchronous round-trip to the system — at most 4 times per second.
    /// (Updating it on every degree dropped the effect from 120 to 35 fps.)
    private func updateStatus() {
        let now = CACurrentMediaTime()
        guard now - lastTitleTime > 0.25 else { return }
        let mode = simAngle == nil ? "" : " (sim)"
        let title = String(format: "∠ %.0f°%@", rawAngle, mode)
        guard title != lastTitle else { return }
        lastTitle = title; lastTitleTime = now
        statusItem.button?.title = title
        statusTime += CACurrentMediaTime() - now; statusCount += 1
    }

    @objc private func useSensor() { simAngle = nil; demoTimer?.invalidate() }

    @objc private func showSimPanel() {
        if simPanel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 80), styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
            p.title = "Lid angle simulation"
            p.level = .floating
            p.isFloatingPanel = true
            let slider = NSSlider(value: 120, minValue: 0, maxValue: 130, target: self, action: #selector(sliderChanged(_:)))
            slider.frame = NSRect(x: 16, y: 24, width: 328, height: 24)
            slider.isContinuous = true
            p.contentView?.addSubview(slider)
            p.center()
            simPanel = p
        }
        simAngle = NSNumber(value: rawAngle)
        simPanel?.orderFront(nil)
    }

    @objc private func sliderChanged(_ s: NSSlider) { simAngle = NSNumber(value: s.doubleValue) }

    /// Scripted run: 120° → 3° in `demoSeconds`, pause, 3° → 120° in `demoSeconds`.
    @objc private func runDemo() {
        demoTimer?.invalidate()
        statusWindow?.window.orderOut(nil)
        let start = CACurrentMediaTime()
        simAngle = 120
        let down = Config.demoSeconds, hold = 0.7, up = Config.demoSeconds
        demoTimer = Timer(timeInterval: 1.0 / 240, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let e = CACurrentMediaTime() - start
            let ease: (Double) -> Double = { x in 0.5 - 0.5 * cos(.pi * x) }
            // Rounded to whole degrees — exactly how the real sensor quantizes.
            if e < down { self.simAngle = NSNumber(value: (120 - 117 * ease(e / down)).rounded()) }
            else if e < down + hold { self.simAngle = 3 }
            else if e < down + hold + up { self.simAngle = NSNumber(value: (3 + 117 * ease((e - down - hold) / up)).rounded()) }
            else { t.invalidate(); self.simAngle = nil; log("Demo finished.") }
        }
        RunLoop.main.add(demoTimer!, forMode: .common)
    }
}

// MARK: - Entry point

// Arguments: --start N --full N --blur N --smooth N --eye-distance N --eye-height N --levels N
//            --demo [--demo-seconds N] --hold N --trace --no-window
let args = CommandLine.arguments
func arg(_ name: String) -> Double? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return Double(args[i + 1])
}
/// Command-line flags win over values persisted from the status window.
func applyCommandLineOverrides() {
    if let v = arg("--start") { Config.startAngle = v }
    if let v = arg("--full") { Config.fullAngle = v }
    if let v = arg("--blur") { Config.maxBlur = v }
    if let v = arg("--strength") { Config.projectionStrength = v }
    if let v = arg("--eye-distance") { Config.eyeDistance = v }
    if let v = arg("--eye-height") { Config.eyeHeight = v }
    if let v = arg("--demo-seconds") { Config.demoSeconds = v }
    if let v = arg("--smooth") { Config.smoothHz = v }
    if args.contains("--trace") { Config.trace = true }
    if let v = arg("--levels") { Config.blurLevels = Int(v) }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
if let hold = arg("--hold") {                       // test: 120° for one second, then a fixed angle
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { controller.setValue(120.0, forKey: "simAngle") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { controller.setValue(hold, forKey: "simAngle") }
}
if args.contains("--demo") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        controller.perform(NSSelectorFromString("runDemo"))
    }
}
app.run()
