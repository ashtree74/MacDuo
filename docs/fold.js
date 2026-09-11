// The lid demo, as a straight port of the iPhone Duo recreation by chuspeeism (Three.js):
// https://github.com/chuspeeism/iphone-duo — screenColor() in main.js.
//
// The screen is a plane hinged at its bottom edge. For every fragment, a ray from a fixed reference
// eye (the camera) is intersected with the screen plane *at the trigger pose*; the picture is sampled
// there. So from the camera the picture stays exactly where it was while the glass moves through it.
// Blur radius and darkening follow the source image coordinate (distance from the hinge), with the
// reference's profiles: radius = 72·motion·g^1.35 texels, darken = min(1, 2·motion·((g−0.2)/0.8)^1.35).
// The 5×5 kernel with continuous mip level and the soft coverage (so colour bleeds into the black
// margin) are the reference's as well. The only change: their hinge runs along x, ours along y.

import * as THREE from "https://cdn.jsdelivr.net/npm/three@0.170.0/build/three.module.js";

const START = 100, FULL = 25;            // same numbers as the app
const W = 1.6, H = 1.0;                  // lid size, world units (16:10)

const stage = document.getElementById("stage");
const canvas = document.getElementById("fold");
const input = document.getElementById("angle");
const out = document.getElementById("angleOut"), state = document.getElementById("state");
const blurOut = document.getElementById("blurOut"), fadeOut = document.getElementById("fadeOut");

const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
renderer.setClearColor(0x000000, 0);
renderer.outputColorSpace = THREE.SRGBColorSpace;

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(30, 16 / 11, 0.1, 50);
camera.position.set(0, 0.62, 3.1);       // the reference eye: in front of the lid, a little above its center
camera.lookAt(0, 0.46, 0);

scene.add(new THREE.AmbientLight(0xffffff, 0.9));
const key = new THREE.DirectionalLight(0xffffff, 2.0); key.position.set(-1.5, 2.5, 3); scene.add(key);
const rim = new THREE.DirectionalLight(0x9fc4ff, 0.6); rim.position.set(2, 1, -2); scene.add(rim);

// ---- lid: bezel + hinge + screen -------------------------------------------------------------
const lid = new THREE.Group();
scene.add(lid);

function roundedRect(w, h, r) {
  const s = new THREE.Shape();
  s.moveTo(-w / 2 + r, 0); s.lineTo(w / 2 - r, 0); s.quadraticCurveTo(w / 2, 0, w / 2, r);
  s.lineTo(w / 2, h - r); s.quadraticCurveTo(w / 2, h, w / 2 - r, h);
  s.lineTo(-w / 2 + r, h); s.quadraticCurveTo(-w / 2, h, -w / 2, h - r);
  s.lineTo(-w / 2, r); s.quadraticCurveTo(-w / 2, 0, -w / 2 + r, 0);
  return s;
}
const bezelGeo = new THREE.ExtrudeGeometry(roundedRect(W + 0.09, H + 0.09, 0.05), { depth: 0.012, bevelEnabled: false });
bezelGeo.translate(0, -0.045, -0.012);
const bezel = new THREE.Mesh(bezelGeo, new THREE.MeshStandardMaterial({ color: 0x4a515e, metalness: 0.6, roughness: 0.4 }));
lid.add(bezel);
const hinge = new THREE.Mesh(new THREE.CylinderGeometry(0.018, 0.018, W * 0.86, 24).rotateZ(Math.PI / 2),
                             new THREE.MeshStandardMaterial({ color: 0x8a8f99, metalness: 0.9, roughness: 0.35 }));
hinge.position.set(0, -0.005, -0.006);
scene.add(hinge);

const texture = new THREE.TextureLoader().load("macos.jpg", t => {
  t.colorSpace = THREE.SRGBColorSpace;
  t.generateMipmaps = true;
  t.minFilter = THREE.LinearMipmapLinearFilter;
  t.magFilter = THREE.LinearFilter;
  t.anisotropy = renderer.capabilities.getMaxAnisotropy();
  uniforms.texel.value.set(1 / t.image.width, 1 / t.image.height);
  t.needsUpdate = true;
});

const uniforms = {
  map: { value: texture },
  eye: { value: camera.position.clone() },
  planeOrigin: { value: new THREE.Vector3(0, 0, 0) },
  planeU: { value: new THREE.Vector3(1, 0, 0) },
  planeV: { value: new THREE.Vector3(0, 1, 0) },
  planeN: { value: new THREE.Vector3(0, 0, 1) },
  size: { value: new THREE.Vector2(W, H) },
  motion: { value: 0 },
  texel: { value: new THREE.Vector2(1 / 1600, 1 / 1037) },
};

const screenMat = new THREE.ShaderMaterial({
  uniforms,
  glslVersion: THREE.GLSL3,
  vertexShader: `
    out vec3 vWorld;
    void main() {
      vec4 wp = modelMatrix * vec4(position, 1.0);
      vWorld = wp.xyz;
      gl_Position = projectionMatrix * viewMatrix * wp;
    }`,
  fragmentShader: `
    precision highp float;
    uniform sampler2D map;
    uniform vec3 eye, planeOrigin, planeU, planeV, planeN;
    uniform vec2 size, texel;
    uniform float motion;
    in vec3 vWorld;
    out vec4 fragColor;
    void main() {
      // Intersect the fixed reference-eye ray with the screen plane at the trigger pose.
      vec3 d = vWorld - eye;
      float denom = dot(d, planeN);
      float t = dot(planeOrigin - eye, planeN) / denom;
      if (abs(denom) < 1e-6 || t <= 0.0) { fragColor = vec4(0.0, 0.0, 0.0, 1.0); return; }
      vec3 rel = eye + d * t - planeOrigin;
      vec2 sourceUV = vec2(dot(rel, planeU) / size.x + 0.5, dot(rel, planeV) / size.y);

      float edge = clamp(sourceUV.y, 0.0, 1.0);               // distance from the hinge, in the source image
      float blurGradient = edge;
      float darkenGradient = clamp((edge - 0.2) / 0.8, 0.0, 1.0);
      float effect = motion * pow(darkenGradient, 1.35);
      float radius = 72.0 * motion * pow(blurGradient, 1.35);

      vec2 aa = max(fwidth(sourceUV), texel * 0.5);
      vec2 dx = dFdx(sourceUV) / texel;
      vec2 dy = dFdy(sourceUV) / texel;
      float baseLod = log2(max(1.0, max(length(dx), length(dy))));
      vec2 coverage = smoothstep(-aa, aa, sourceUV) * (1.0 - smoothstep(vec2(1.0) - aa, vec2(1.0) + aa, sourceUV));
      vec3 color = textureLod(map, clamp(sourceUV, vec2(0.0), vec2(1.0)), baseLod).rgb * coverage.x * coverage.y;
      if (radius > 0.0) {
        float lod = max(baseLod, log2(max(1.0, radius)));
        vec2 footprint = max(aa, texel * radius * 0.75);
        color = vec3(0.0);
        for (int y = -2; y <= 2; y++) {
          for (int x = -2; x <= 2; x++) {
            float wx = x == 0 ? 6.0 : (abs(x) == 1 ? 4.0 : 1.0);
            float wy = y == 0 ? 6.0 : (abs(y) == 1 ? 4.0 : 1.0);
            vec2 sampleUV = sourceUV + vec2(float(x), float(y)) * texel * radius;
            // Blur the image and its coverage together so colour spreads into the black margin.
            vec2 cov = smoothstep(-footprint, footprint, sampleUV) * (1.0 - smoothstep(vec2(1.0) - footprint, vec2(1.0) + footprint, sampleUV));
            color += textureLod(map, clamp(sampleUV, vec2(0.0), vec2(1.0)), lod).rgb * cov.x * cov.y * wx * wy / 256.0;
          }
        }
      }
      fragColor = vec4(color * (1.0 - min(1.0, effect * 2.0)), 1.0);
    }`,
});
const screenGeo = new THREE.PlaneGeometry(W, H).translate(0, H / 2, 0.001);
lid.add(new THREE.Mesh(screenGeo, screenMat));

// The reference plane: the lid at the trigger pose (rotation about the hinge by 90° − START).
const lidRotation = a => THREE.MathUtils.degToRad(90 - a);   // positive tips the top towards the camera
{
  const q = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(1, 0, 0), lidRotation(START));
  uniforms.planeV.value.set(0, 1, 0).applyQuaternion(q);
  uniforms.planeN.value.set(0, 0, 1).applyQuaternion(q);
}

// ---- state / readouts ------------------------------------------------------------------------
let target = +input.value, shown = target, raf = null;

function render(a) {
  const raw = Math.max(0, Math.min(1, (START - a) / (START - FULL)));
  const motion = raw * raw * (3 - 2 * raw);   // smoothstep, as `motion` in the reference
  lid.rotation.x = lidRotation(a);
  uniforms.motion.value = a < START ? motion : 0;
  renderer.render(scene, camera);
  out.innerHTML = Math.round(a) + "<span>°</span>";
  blurOut.textContent = Math.round(motion * 72) + " px";
  fadeOut.textContent = Math.round(Math.min(1, motion * 2) * 100) + " %";
  state.textContent = a >= START ? "lid open · watching" : a <= FULL ? "folded · fully faded" : "folding · effect live";
}
function tick() {
  shown += (target - shown) * 0.18;
  if (Math.abs(target - shown) < 0.05) { shown = target; raf = null; } else raf = requestAnimationFrame(tick);
  render(shown);
}
input.addEventListener("input", () => { target = +input.value; if (!raf) raf = requestAnimationFrame(tick); });

function resize() {
  const w = stage.clientWidth, h = stage.clientHeight;
  renderer.setSize(w, h, false);
  camera.aspect = w / h; camera.updateProjectionMatrix();
  render(shown);
}
new ResizeObserver(resize).observe(stage);
texture.addEventListener?.("update", () => render(shown));
setTimeout(() => render(shown), 300);   // once the texture has most likely arrived
resize();

// One scripted close-and-open when the demo first scrolls into view (unless the visitor prefers less motion).
if (!matchMedia("(prefers-reduced-motion: reduce)").matches && "IntersectionObserver" in window) {
  let played = false;
  const io = new IntersectionObserver(entries => {
    if (played || !entries.some(e => e.isIntersecting)) return;
    played = true; io.disconnect();
    const t0 = performance.now(), down = 2200, hold = 700, up = 2200;
    const ease = x => 0.5 - 0.5 * Math.cos(Math.PI * x);
    (function sweep(now) {
      const e = now - t0; let a;
      if (e < down) a = 108 - 105 * ease(e / down);
      else if (e < down + hold) a = 3;
      else if (e < down + hold + up) a = 3 + 105 * ease((e - down - hold) / up);
      else { input.value = 108; target = 108; shown = 108; render(108); return; }
      input.value = Math.round(a); target = a; shown = a; render(a);
      requestAnimationFrame(sweep);
    })(t0);
  }, { threshold: 0.6 });
  io.observe(document.getElementById("try"));
}
