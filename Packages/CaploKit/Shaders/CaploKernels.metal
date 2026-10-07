// Caplo 的 Core Image 内核（Metal 可缝合函数，macOS 12 起不需要 -fcikernel 等特殊编译参数）。
//
// 由 Scripts/build-kernels.sh 预编译成 Sources/RenderKit/Resources/CaploKernels.metallib 随包发布：
// SwiftPM 不负责编译 Metal，运行时编译的 Core Image 内核语言（CIKL）又早已弃用，新系统上有被移除的风险。
// 每个函数与 Swift 里保留的 CIKL 兜底版本逐行对应，改一处必须同步另一处（并重跑脚本）。

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

// MARK: - 卡片形状（CardShape.swift）

static float cardDistance(float2 p, float2 center, float2 halfSize, float r, float power) {
    float2 q = abs(p - center) - (halfSize - float2(r, r));
    float2 qc = max(q, float2(0.0, 0.0));
    float n = power > 2.5 ? pow(pow(qc.x, power) + pow(qc.y, power), 1.0 / power) : length(qc);
    return n + min(max(q.x, q.y), 0.0) - r;
}

extern "C" {

[[stitchable]] float4 cardCoverage(float2 center, float2 halfSize, float radius, float power, coreimage::destination dest) {
    float2 p = dest.coord();
    float c = 1.0 - smoothstep(-0.5, 0.5, cardDistance(p + float2(-0.25, -0.25), center, halfSize, radius, power));
    c += 1.0 - smoothstep(-0.5, 0.5, cardDistance(p + float2(0.25, -0.25), center, halfSize, radius, power));
    c += 1.0 - smoothstep(-0.5, 0.5, cardDistance(p + float2(-0.25, 0.25), center, halfSize, radius, power));
    c += 1.0 - smoothstep(-0.5, 0.5, cardDistance(p + float2(0.25, 0.25), center, halfSize, radius, power));
    c *= 0.25;
    return float4(c, c, c, c);
}

[[stitchable]] float4 cardShadow(float2 center, float2 halfSize, float radius, float power, float blur, float opacity, coreimage::destination dest) {
    float d = cardDistance(dest.coord(), center, halfSize, radius, power);
    float a = opacity * (1.0 - smoothstep(-blur, blur, d));
    return float4(0.0, 0.0, 0.0, a);
}

// MARK: - 透明玻璃光标（LiquidGlass.swift）

[[stitchable]] float4 liquidGlass(coreimage::sampler src, float2 center, float radius, float opacity, coreimage::destination dest) {
    float2 p = dest.coord();
    float2 d = p - center;
    float r = length(d);
    float t = clamp(r / radius, 0.0, 1.0);
    float2 dir = r > 0.0001 ? d / r : float2(0.0, 0.0);
    float2 sd = p - (center + float2(0.0, -0.1 * radius));
    float shadowAlpha = 0.38 * (1.0 - smoothstep(0.84, 1.42, length(sd) / radius));
    float4 shadow = float4(0.0, 0.0, 0.0, shadowAlpha);
    float coverage = 1.0 - smoothstep(radius - 0.75, radius + 0.75, r);
    if (coverage <= 0.0) { return shadow * opacity; }
    float rim = smoothstep(0.35, 1.0, t);
    float bend = rim * rim * (3.0 - 2.0 * rim);
    float factor = 0.7 + 1.2 * bend;
    float2 base = center + d * factor;
    float2 step = dir * (0.02 * radius * bend);
    float4 mid = (src.sample(src.transform(base - 2.0 * step)) + src.sample(src.transform(base - step))
                  + src.sample(src.transform(base)) + src.sample(src.transform(base + step))
                  + src.sample(src.transform(base + 2.0 * step))) / 5.0;
    float2 spread = dir * (0.06 * radius * bend);
    float red = src.sample(src.transform(base + spread)).r;
    float blue = src.sample(src.transform(base - spread)).b;
    float4 glass = float4(mix(mid.r, red, 0.9), mid.g, mix(mid.b, blue, 0.9), mid.a);
    float2 light = normalize(float2(-0.6, 0.8));
    float facing = dot(dir, light);
    float3 white = float3(glass.a, glass.a, glass.a);
    float sheen = smoothstep(-0.2, 0.9, dot(d / radius, light)) * 0.12 * (1.0 - 0.5 * t);
    float glow = smoothstep(0.5, 1.0, t);
    glow = glow * glow * 0.42;
    float arc = smoothstep(0.66, 0.84, t) * (1.0 - smoothstep(0.84, 0.92, t)) * pow(max(facing, 0.0), 2.5) * 0.6;
    float bounce = smoothstep(0.7, 0.86, t) * (1.0 - smoothstep(0.86, 0.93, t)) * pow(max(-facing, 0.0), 3.0) * 0.32;
    glass.rgb = mix(glass.rgb, white, min(1.0, sheen + glow + arc + bounce));
    float inner = smoothstep(0.8, 0.92, t) * (1.0 - smoothstep(0.92, 0.97, t));
    glass.rgb = glass.rgb * (1.0 - inner * (0.12 + 0.2 * (0.5 - 0.5 * facing)));
    float ring = smoothstep(0.87, 0.975, t);
    float lit = 0.5 + 0.5 * pow(max(facing, 0.0), 1.1) + 0.6 * pow(max(-facing, 0.0), 1.5);
    glass.rgb = mix(glass.rgb, white, min(1.0, ring * lit));
    float4 layer = glass * coverage;
    layer = layer + shadow * (1.0 - layer.a);
    return layer * opacity;
}

}
