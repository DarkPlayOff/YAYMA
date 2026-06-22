#extension GL_GOOGLE_include_directive : enable

precision highp float;

#include <flutter/runtime_effect.glsl>

uniform vec2 vScreenSize;
uniform float vTime;
uniform float vScale;
uniform vec3 vColorBackground;
uniform vec3 vColor[6];
uniform vec3 vRotation[3];
uniform float vAudio[3];
uniform float vReact[3];

out vec4 fragColor;

#define CIRCLE_WIDTH_BASE 0.9
#define CIRCLE_WIDTH_STEP 0.2
#define SPARK_STRENGTH_BASE 1.0
#define SPARK_STRENGTH_STEP 0.3
#define CIRCLE_RADIUS_BASE 1.1
#define CIRCLE_RADIUS_STEP 0.15
#define CIRCLE_OFFSET_BASE 0.0
#define CIRCLE_OFFSET_STEP 1.57
#define PI 3.14159265
#define INV_TWO_PI 0.15915494

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

float triNoise3D(vec3 p, float spd) {
  float rz = 0.1;
  vec3 bp = p;
  float timeOffset = vTime * 0.1 * spd;
  float z_inv = 2.7777778;

  for (int i = 0; i < 5; i++) {
    vec3 bp_01 = bp * 0.01;
    vec3 dg = vec3(tri(bp_01.z + 0.5), tri(bp_01.z + tri(bp_01.x)), tri(tri(bp_01.x)));
    p += (dg + timeOffset);
    bp *= 4.0;
    p *= 1.6;
    rz += tri(p.z + tri(0.6 * p.x + 0.1 * tri(p.y))) * z_inv;
    z_inv *= 1.1111111;
  }
  return smoothstep(0.0, 8.0, rz + sin(rz + 0.655213) * 2.2);
}

vec2 rotate(vec2 p, float a) {
  float s = sin(a);
  float c = cos(a);
  return vec2(p.x * c - p.y * s, p.x * s + p.y * c);
}

float light(float intensity, float dist) {
  return intensity / (1.0 + dist * 11.0);
}

vec4 makeNoiseBlob2(vec2 uv, vec3 color1, vec3 color2, float strength,
                    float offset) {
  float len = length(uv);
  float n0 = snoise3(vec3(uv * 1.2 + offset, vTime * 0.5 + offset)) * 0.5 + 0.5;

  float d0 = abs(len - n0);
  float v0 = smoothstep(n0 + 0.1 + (sin(vTime + offset) + 1.0), n0, len);
  float v1 = light(
      0.15 - 0.1125 * sin(vTime * 2.0 + offset * 0.5) + 0.3 * strength, d0);

  vec3 col = mix(color1, color2, clamp(uv.y * 2.0, 0.0, 1.0));
  return vec4(clamp(col + v1, 0.0, 1.0), v0);
}

vec4 makeBlob(vec2 uv, float len, float blob, vec3 color1, vec3 color2, float width,
              float baseReaction, float likeReaction, float audioStrength,
              float offset, vec2 noiseOffset) {
  float outerRadius =
      blob + width * 0.5 +
      baseReaction *
          (1.0 + max(likeReaction, audioStrength * 0.6) * 50.0 * baseReaction);

  float strength = max(likeReaction, audioStrength);
  vec4 noise = makeNoiseBlob2(uv * (1.0 - likeReaction * 0.5) + noiseOffset,
                              color1, color2, strength, offset);

  noise.a *= smoothstep(outerRadius, 0.5, len);
  noise.rgb +=
      0.6 * likeReaction * (1.0 - smoothstep(0.2, outerRadius * 0.8, len));

  return noise;
}

void main() {
  vec2 fragCoord = FlutterFragCoord().xy;
  vec2 uv = (fragCoord * 2.0 - vScreenSize) / (min(vScreenSize.x, vScreenSize.y) * vScale);

  float pa = atan(uv.y, uv.x);
  float idx = pa * INV_TWO_PI;

  float pa1 = pa > 0.0 ? pa - PI : pa + PI;
  float idx1 = pa1 * INV_TWO_PI;
  float idx21 = pa1 * 0.5 + PI * 0.5;
  float spark = triNoise3D(vec3(idx, 0.0, 0.0), 0.1);

  float sinIdx21 = sin(idx21);
  if (sinIdx21 > 0.9) {
    float blend = smoothstep(0.9, 1.0, sinIdx21);
    spark = mix(spark, triNoise3D(vec3(idx1, 0.0, idx1), 0.1), blend);
  }

  float s2 = spark * spark;
  float s4 = s2 * s2;
  float s8 = s4 * s4;
  float s10 = s8 * s2;
  spark = spark * 0.2 + s10;
  spark = smoothstep(0.0, spark, 0.3) * spark;

  vec3 color = vColorBackground;
  float n0 = snoise3(vec3(uv * 1.2, vTime * 0.5));
  float n0_03 = n0 * 0.3;
  float mainLen = length(uv);

  for (int i = 0; i < 3; i++) {
    float fi = float(i);
    float radius = CIRCLE_RADIUS_BASE - CIRCLE_RADIUS_STEP * fi;
    vec4 blobColor = makeBlob(
        uv, mainLen, radius + n0_03, vColor[i], vColor[i + 3],
        CIRCLE_WIDTH_BASE - CIRCLE_WIDTH_STEP * fi,
        (SPARK_STRENGTH_BASE - SPARK_STRENGTH_STEP * fi) * spark, vReact[i],
        vAudio[i], CIRCLE_OFFSET_BASE + CIRCLE_OFFSET_STEP * fi,
        rotate(vRotation[i].xy, vTime * vRotation[i].z));
    color = mix(color, blobColor.rgb, blobColor.a);
  }

  fragColor = vec4(color, 1.0);
}