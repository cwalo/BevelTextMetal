#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct ShaderUniforms {
    float2 lightDir;
    float  borderWidth;
    float3 borderShadow;   // dark side of the bevel
    float3 borderLit;      // lit side of the bevel
    float3 faceFill;       // flat glyph interior
};

vertex VertexOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1, -1), float2( 1, -1),
        float2(-1,  1), float2( 1,  1)
    };
    // Y-flip the texCoord so the CG-rasterized bitmap (Y-up) reads upright
    // through Metal's Y-down texture sampling.
    float2 texCoords[4] = {
        float2(0, 1), float2(1, 1),
        float2(0, 0), float2(1, 0)
    };
    VertexOut out;
    out.position = float4(positions[vid], 0, 1);
    out.texCoord = texCoords[vid];
    return out;
}

// Photoshop-style layer compositing on a signed distance field. The SDF is
// in normalized pixel units (1.0 == half the texture's longer side in pixels).
fragment float4 bevelFragment(
    VertexOut         in        [[stage_in]],
    texture2d<float>  sdfTex    [[texture(0)]],
    constant ShaderUniforms& U  [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float sdf = sdfTex.sample(s, in.texCoord).r;

    // ---- Outward unit-direction in screen space (smooth derivatives) ----
    float2 grad   = float2(dfdx(sdf), dfdy(sdf));
    float  gl     = length(grad);
    float2 outward = (gl > 1e-6) ? -grad / gl : float2(0);

    // Single smooth 0..1 brightness term running continuously around the
    // perimeter — 1 where the surface faces the light, 0 where it faces
    // away. No clipping at zero, so corners don't show a facet.
    float lit         = dot(outward, U.lightDir); // -1..+1
    float bevelBright = lit * 0.5 + 0.5;          // 0..1

    // ---- Layer thresholds (normalized SDF units) ----
    const float aa           = 0.0008;       // ~1 screen pixel at our scale
    float       borderWidth  = U.borderWidth;
    const float shadowExtent = 0.0280;       // soft drop-shadow falloff

    // ---- Palette ----
    const float3 shadowColor = float3(0.00);

    // The outer border is the beveled element — its color slides smoothly
    // around the glyph perimeter from "facing away from light" (darker) to
    // "facing toward light" (brighter). The glyph face itself stays flat.
    float3 borderColor = mix(U.borderShadow, U.borderLit, bevelBright);

    // ---- Layer-on-layer alpha compositing (outside -> inside) ----
    // Drop shadow ramps up from the far outer edge to where the border begins.
    // Border (with bevel lighting) sits in [-borderWidth, 0]. Face fills sdf >= 0.
    float dropAlpha  = smoothstep(-shadowExtent, -borderWidth - aa, sdf) * 0.45;
    float borderMask = smoothstep(-borderWidth - aa, -borderWidth + aa, sdf);
    float faceMask   = smoothstep(-aa, aa, sdf);

    float3 color = mix(shadowColor, borderColor, borderMask);
    color        = mix(color,       U.faceFill,  faceMask);

    float alpha = mix(dropAlpha, 1.0, borderMask);
    alpha       = mix(alpha,     1.0, faceMask);

    if (alpha < 0.005) discard_fragment();
    return float4(color, alpha);
}
