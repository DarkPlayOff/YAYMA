#extension GL_GOOGLE_include_directive : enable

precision highp float;

#include <flutter/runtime_effect.glsl>

// Uniform indices are assigned manually in PixelPerfectVibePainter
// (lib/src/features/core/views/layout/background.dart). All per-frame
// constants (blob rotation offsets, sin() phases, audio/like reactions)
// are precomputed there — keep both files in sync.
uniform vec2 vScreenOffset; // 0-1: screenSize / (min(w,h) * scale)
uniform float vUvScale;     // 2:   2 / (min(w,h) * scale)
uniform float vNoiseTime;   // 3:   time * 0.5
uniform float vTriTime;     // 4:   time * 0.01
uniform float vMaxOuter;    // 5:   upper bound of any blob outer radius
uniform vec3 vColor[6];     // 6-23
uniform vec4 vBlobA[3];     // 24-35: xy noise offset, z noise time+phase, w uv scale
uniform vec4 vBlobB[3];     // 36-47: x edge widen, y light intensity, z audio boost, w like glow

out vec4 fragColor;

#define PI 3.14159265
#define INV_TWO_PI 0.15915494
// Tames how far spark peaks push blob edges outward (see main()).
#define SPARK_GAIN 0.4

const float INV_289 = 1.0 / 289.0;

vec3 mod289(vec3 x) { return x - floor(x * INV_289) * 289.0; }
vec4 mod289(vec4 x) { return x - floor(x * INV_289) * 289.0; }

vec4 permute(vec4 x) { return mod289((x * 34.0 + 1.0) * x); }

float snoise3(vec3 v) {
  vec3 i = floor(v + dot(v, vec3(0.3333333)));
  vec3 x0 = v - i + dot(i, vec3(0.1666667));
  vec3 g = step(x0.yzx, x0.xyz);
  vec3 l = 1.0 - g;
  vec3 i1 = min(g.xyz, l.zxy);
  vec3 i2 = max(g.xyz, l.zxy);

  vec3 x1 = x0 - i1 + 0.1666667;
  vec3 x2 = x0 - i2 + 0.3333333;
  vec3 x3 = x0 - 0.5;

  i = mod289(i);

  vec4 p = permute(permute(permute(i.z + vec4(0.0, i1.z, i2.z, 1.0)) + i.y +
                           vec4(0.0, i1.y, i2.y, 1.0)) +
                   i.x + vec4(0.0, i1.x, i2.x, 1.0));

  const vec3 ns = vec3(0.285714285714, -0.928571428571, 0.142857142857);
  vec4 j = p - 49.0 * floor(p * ns.z * ns.z);
  vec4 x_ = floor(j * ns.z);
  vec4 y_ = floor(j - 7.0 * x_);
  vec4 x = x_ * ns.x + ns.yyyy;
  vec4 y = y_ * ns.x + ns.yyyy;
  vec4 h = 1.0 - abs(x) - abs(y);
  vec4 b0 = vec4(x.xy, y.xy);
  vec4 b1 = vec4(x.zw, y.zw);
  vec4 s0 = floor(b0) * 2.0 + 1.0;
  vec4 s1 = floor(b1) * 2.0 + 1.0;
  vec4 sh = -step(h, vec4(0.0));
  vec4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
  vec4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
  vec3 p0 = vec3(a0.xy, h.x);
  vec3 p1 = vec3(a0.zw, h.y);
  vec3 p2 = vec3(a1.xy, h.z);
  vec3 p3 = vec3(a1.zw, h.w);

  vec4 norm = inversesqrt(vec4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
  p0 *= norm.x;
  p1 *= norm.y;
  p2 *= norm.z;
  p3 *= norm.w;

  vec4 m = max(0.6 - vec4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
  m = m * m;
  return 42.0 * dot(m * m, vec4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
}

float tri(float x) { return abs(fract(x) - 0.5); }

// triNoise3D specialized for input (x, 0, 0): bp.yz stay zero, so
// dg = (0, t, t) and p.y == p.z on every iteration — scalar math only.
float triNoiseAngle(float x) {
  float rz = 0.1;
  float bx = x * 0.01;
  float px = x;
  float pyz = 0.0;
  float w = 2.7777778;

  for (int i = 0; i < 5; i++) {
    float t = tri(tri(bx));
    px = (px + vTriTime) * 1.6;
    pyz = (pyz + t + vTriTime) * 1.6;
    bx *= 4.0;
    rz += tri(pyz + tri(0.6 * px + 0.1 * tri(pyz))) * w;
    w *= 1.1111111;
  }
  return smoothstep(0.0, 8.0, rz + sin(rz + 0.655213) * 2.2);
}

// triNoise3D specialized for input (x, 0, x): bp.x == bp.z on every iteration.
float triNoiseSeam(float x) {
  float rz = 0.1;
  float b = x * 0.01;
  vec3 p = vec3(x, 0.0, x);
  float w = 2.7777778;

  for (int i = 0; i < 5; i++) {
    float tb = tri(b);
    p = (p + vec3(tri(b + 0.5), tri(b + tb), tri(tb)) + vTriTime) * 1.6;
    b *= 4.0;
    rz += tri(p.z + tri(0.6 * p.x + 0.1 * tri(p.y))) * w;
    w *= 1.1111111;
  }
  return smoothstep(0.0, 8.0, rz + sin(rz + 0.655213) * 2.2);
}

void main() {
  vec2 uv = FlutterFragCoord().xy * vUvScale - vScreenOffset;
  float mainLen = length(uv);

  if (mainLen >= vMaxOuter) {
    fragColor = vec4(0.0, 0.0, 0.0, 1.0);
  } else {
    float angle = atan(uv.y, uv.x);
    float spark = triNoiseAngle(angle * INV_TWO_PI);

    // Blend in a second noise field across the atan() seam at angle == +-PI.
    float seam = abs(sin(angle * 0.5));
    if (seam > 0.9) {
      float wrappedAngle = angle > 0.0 ? angle - PI : angle + PI;
      spark = mix(spark, triNoiseSeam(wrappedAngle * INV_TWO_PI), smoothstep(0.9, 1.0, seam));
    }

    float sparkSq = spark * spark;
    float sparkQuad = sparkSq * sparkSq;
    spark = spark * 0.2 + sparkQuad * sparkQuad * sparkSq;
    spark = smoothstep(0.0, 0.3, spark) * spark * SPARK_GAIN;

    vec3 color = vec3(0.0);
    float baseNoise = snoise3(vec3(uv * 1.2, vNoiseTime)) * 0.3;

    for (int i = 0; i < 3; i++) {
      float blobIndex = float(i);
      vec4 blobA = vBlobA[i];
      vec4 blobB = vBlobB[i];

      float sparkBoost = (1.0 - 0.3 * blobIndex) * spark;
      // 1.55 - 0.25*blobIndex == radius (1.1 - 0.15*blobIndex) + halfWidth (0.45 - 0.1*blobIndex)
      float outer = 1.55 - 0.25 * blobIndex + baseNoise + sparkBoost * (1.0 + blobB.z * sparkBoost);

      // Alpha is exactly 0 at mainLen >= outer — skip both snoise3 and shading.
      if (mainLen < outer) {
        vec2 blobUv = uv * blobA.w + blobA.xy;
        float blobLen = length(blobUv);
        float blobNoise = snoise3(vec3(blobUv * 1.2 + 1.57 * blobIndex, blobA.z)) * 0.5 + 0.5;
        float edgeMask = smoothstep(blobNoise + blobB.x, blobNoise, blobLen);
        float coreGlow = blobB.y / (1.0 + abs(blobLen - blobNoise) * 11.0);

        vec3 blobColor = clamp(mix(vColor[i], vColor[i + 3], clamp(blobUv.y * 2.0, 0.0, 1.0)) + coreGlow,
                         0.0, 1.0) +
                   blobB.w * (1.0 - smoothstep(0.2, outer * 0.8, mainLen));
        color = mix(color, blobColor, edgeMask * smoothstep(outer, 0.5, mainLen));
      }
    }

    fragColor = vec4(color, 1.0);
  }
}
