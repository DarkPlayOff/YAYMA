#extension GL_GOOGLE_include_directive : enable

precision highp float;

#include <flutter/runtime_effect.glsl>

// Uniform indices are assigned manually in PixelPerfectVibePainter
// (lib/src/features/core/views/layout/background.dart). Curtain geometry is
// constant per layer and precomputed there; only time/audio/like values change
// per tick — keep both files in sync.
uniform vec2 vScreenOffset; // 0-1: screenSize / min(w, h)
uniform float vUvScale;     // 2:   2 / min(w, h)
uniform float vNoiseTime;   // 3:   time * 0.5
uniform float vTriTime;     // 4:   time * 0.01 (slow horizontal drift)
uniform float vGain;        // 5:   overall brightness, from player energy
uniform vec3 vColor[6];     // 6-23
uniform vec4 vCurtainA[3];  // 24-35: x drift, y ridge height, z phase, w horizontal frequency
uniform vec4 vCurtainB[3];  // 36-47: x tail fade rate, y intensity, z audio boost, w like glow

out vec4 fragColor;

// Sideways sway of a curtain's wavy lower edge, in screen units.
#define SWAY 0.45

// 2D simplex noise. A 2D slice of 3D simplex has the same character at about
// half the cost, and the third coordinate only ever seeded each layer.
const float INV_289 = 1.0 / 289.0;

vec2 mod289v(vec2 x) { return x - floor(x * INV_289) * 289.0; }
vec3 mod289v(vec3 x) { return x - floor(x * INV_289) * 289.0; }
vec3 permute(vec3 x) { return mod289v((x * 34.0 + 1.0) * x); }

float snoise2(vec2 v) {
  const vec4 C = vec4(
    0.211324865405187, 0.366025403784439,
    -0.577350269189626, 0.024390243902439);
  vec2 i = floor(v + dot(v, C.yy));
  vec2 x0 = v - i + dot(i, C.xx);

  vec2 i1 = x0.x > x0.y ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
  vec4 x12 = x0.xyxy + C.xxzz;
  x12.xy -= i1;

  i = mod289v(i);
  vec3 p = permute(permute(i.y + vec3(0.0, i1.y, 1.0)) + i.x + vec3(0.0, i1.x, 1.0));

  vec3 m = max(0.5 - vec3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
  m = m * m;
  m = m * m;

  vec3 x = 2.0 * fract(p * C.www) - 1.0;
  vec3 h = abs(x) - 0.5;
  vec3 ox = floor(x + 0.5);
  vec3 a0 = x - ox;
  m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);

  vec3 g;
  g.x = a0.x * x0.x + h.x * x0.y;
  g.yz = a0.yz * x12.xz + h.yz * x12.yw;
  return 130.0 * dot(m, g);
}

void main() {
  // Normalized screen coords: x in [-aspect, aspect], y in [-1, 1].
  vec2 uv = FlutterFragCoord().xy * vUvScale - vScreenOffset;
  float y = -uv.y; // +1 at the top of the window
  float t = vNoiseTime;

  vec3 color = vec3(0.0);

  for (int i = 0; i < 3; i++) {
    vec4 a = vCurtainA[i];
    vec4 b = vCurtainB[i];

    // Wavy lower edge of the curtain, drifting sideways.
    float x = uv.x * a.w + a.x + vTriTime * (0.8 + 0.4 * float(i));
    float n = snoise2(vec2(x * 0.3, t * 0.07 + a.z));
    // The cubic term sharpens the wave crests so the edge isn't a plain sine.
    float ridge = a.y + n * SWAY + n * n * n * 0.2;
    float d = ridge - y; // > 0 below the ridge
    // Beyond the fade there is no visible light.
    if (d < -0.6 || d > 2.5) continue;

    // Filaments: noise stretched along y so the curtain hangs in vertical rays.
    // The low-frequency field bends them sideways, the sine makes them snake
    // as they fall, so the strands hang like fabric instead of standing bars.
    // The power keeps them narrow with dark gaps instead of a flat wash.
    float sway = n * 0.5 + 0.15 * sin(y * 1.5 + t * 0.4 + x * 0.8);
    float rays = snoise2(vec2((x + sway) * 3.5, y * 0.25 - t * 0.3 + a.z * 2.0)) * 0.5 + 0.5;
    rays = 0.12 + rays * rays * rays * 1.9;
    // Broad patches of light along the curtain, so it isn't evenly bright.
    float patches = 0.4 + 0.6 * clamp(n * 1.2 + 0.6, 0.0, 1.0);

    // Bright at the edge, a long tail below it, a short fade above.
    float prof = exp(-max(d, 0.0) * b.x - max(-d, 0.0) * 6.0);
    float glow = prof * rays * patches * b.y * (1.0 + b.z + b.w);

    vec3 tint = mix(vColor[i], vColor[i + 3], clamp(d * 1.2, 0.0, 1.0));
    tint = mix(tint, vec3(1.0), prof * prof * 0.2);
    color += tint * glow;
  }

  // Keep the bottom of the window dark so the player controls stay readable.
  color *= smoothstep(-1.0, -0.25, y);
  color *= clamp(vGain, 0.0, 1.5);

  fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
