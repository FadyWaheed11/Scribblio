// Shaders are compiled from source at launch, so the build needs no Metal toolchain.
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 lightDir;
    float4 floorRect;
    float2 viewSize;
    float2 lightK;
    float2 shadowMapSize;
    float camD;
    float floorZ;
    float shadowStrength;
};

struct V { float4 pos; float4 nrm; };

constant float2 poisson[16] = {
    float2(-0.94201624, -0.39906216), float2(0.94558609, -0.76890725),
    float2(-0.09418410, -0.92938870), float2(0.34495938, 0.29387760),
    float2(-0.91588581, 0.45771432), float2(-0.81544232, -0.87912464),
    float2(-0.38277543, 0.27676845), float2(0.97484398, 0.75648379),
    float2(0.44323325, -0.97511554), float2(0.53742981, -0.47373420),
    float2(-0.26496911, -0.41893023), float2(0.79197514, 0.19090188),
    float2(-0.24188840, 0.99706507), float2(-0.81409955, 0.91437590),
    float2(0.19984126, 0.78641367), float2(0.14383161, -0.14100790)
};

static float depthFromZ(float z) { return clamp(0.5 - z / 4000.0, 0.0, 1.0); }

static float2 toTC(float2 f, constant Uniforms& u) {
    return float2(f.x / u.viewSize.x, 1.0 - f.y / u.viewSize.y);
}

static float ign(float2 px) {
    return fract(52.9829189 * fract(dot(px, float2(0.06711056, 0.00583715))));
}

// Soft shadow from the height map (PCSS). p is the receiving point, gp the slope of the receiving plane in map space.
static float shadowAt(float3 p, float2 gp, float bias, float2 px,
                      texture2d<float> sm, sampler s, constant Uniforms& u) {
    float2 f = p.xy - u.lightK * p.z;
    float a = ign(px) * 6.2831853;
    float2x2 R = float2x2(float2(cos(a), sin(a)), float2(-sin(a), cos(a)));
    float sumD = 0.0, nB = 0.0;
    for (int i = 0; i < 16; i++) {
        float2 o = R * poisson[i] * 34.0;
        float zr = p.z + dot(gp, o);
        float occ = sm.sample(s, toTC(f + o, u)).r;
        if (occ > zr + bias) { sumD += occ - zr; nB += 1.0; }
    }
    if (nB < 0.5) return 0.0;
    float r = clamp(2.5 + (sumD / nB) * 0.2, 2.5, 30.0);
    float sh = 0.0;
    for (int i = 0; i < 16; i++) {
        float2 o = R * poisson[i] * r;
        float zr = p.z + dot(gp, o);
        float occ = sm.sample(s, toTC(f + o, u)).r;
        sh += (occ > zr + bias) ? 1.0 : 0.0;
    }
    return sh / 16.0;
}

// Pass 1. Height map of everything that casts a shadow, seen from the light onto the desktop.
struct ShadowOut { float4 position [[position]]; float z; float2 uv; };

vertex ShadowOut shadow_vs(uint vid [[vertex_id]],
                           const device V* verts [[buffer(0)]],
                           const device float2* uvs [[buffer(1)]],
                           constant Uniforms& u [[buffer(2)]]) {
    float3 p = verts[vid].pos.xyz;
    float2 f = p.xy - u.lightK * p.z;
    float2 c = u.viewSize * 0.5;
    ShadowOut o;
    o.position = float4((f - c) / c, depthFromZ(p.z), 1.0);
    o.z = p.z;
    o.uv = uvs[vid];
    return o;
}

// burnt and torn parts of a sheet cast no shadow
fragment float4 shadow_fs(ShadowOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler ts [[sampler(0)]]) {
    if (tex.sample(ts, in.uv).a < 0.5) discard_fragment();
    return float4(in.z, 0.0, 0.0, 1.0);
}

// Pass 2. Shadow on the desktop, drawn only in a box around the sheets.
struct FloorOut { float4 position [[position]]; float2 xy; };

vertex FloorOut floor_vs(uint vid [[vertex_id]], constant Uniforms& u [[buffer(2)]]) {
    float4 r = u.floorRect;
    float2 xy = float2((vid & 1) ? r.z : r.x, (vid & 2) ? r.w : r.y);
    float2 c = u.viewSize * 0.5;
    FloorOut o;
    o.position = float4((xy - c) / c, 0.999, 1.0);
    o.xy = xy;
    return o;
}

fragment float4 floor_fs(FloorOut in [[stage_in]],
                         texture2d<float> sm [[texture(1)]],
                         sampler ss [[sampler(1)]],
                         constant Uniforms& u [[buffer(2)]]) {
    float s = shadowAt(float3(in.xy, u.floorZ), float2(0.0), 0.5, in.position.xy, sm, ss, u);
    float a = s * u.shadowStrength;
    return float4(0.035, 0.02, 0.01, 1.0) * a;
}

// Pass 3. The sheets of paper.
struct SheetOut {
    float4 position [[position]];
    float3 world;
    float3 nrm;
    float2 uv;
};

vertex SheetOut sheet_vs(uint vid [[vertex_id]],
                         const device V* verts [[buffer(0)]],
                         const device float2* uvs [[buffer(1)]],
                         constant Uniforms& u [[buffer(2)]]) {
    float3 p = verts[vid].pos.xyz;
    float2 c = u.viewSize * 0.5;
    float w = (u.camD - p.z) / u.camD;
    SheetOut o;
    o.position = float4((p.xy - c) / c, depthFromZ(p.z) * w, w);
    o.world = p;
    o.nrm = verts[vid].nrm.xyz;
    o.uv = uvs[vid];
    return o;
}

fragment float4 sheet_fs(SheetOut in [[stage_in]],
                         bool front [[front_facing]],
                         texture2d<float> tex [[texture(0)]],
                         texture2d<float> sm [[texture(1)]],
                         sampler ts [[sampler(0)]],
                         sampler ss [[sampler(1)]],
                         constant Uniforms& u [[buffer(2)]]) {
    float3 Ng = normalize(in.nrm);
    float3 N = front ? Ng : -Ng;
    float4 tc = tex.sample(ts, in.uv);
    // torn and burnt edges: drop what is transparent, take the color out of premultiplied alpha
    if (tc.a < 0.5) discard_fragment();
    float3 col = tc.rgb / max(tc.a, 0.001);

    // a faint relief from brightness, so ink and fibres catch the light
    float h = dot(col, float3(0.299, 0.587, 0.114));
    float2 g = float2(dfdx(h), -dfdy(h)) * 0.25;
    float3 Nd = normalize(N - float3(g, 0.0));

    // back of the paper, the ink shows through a little
    if (!front) col = mix(col, float3(0.93, 0.91, 0.84), 0.8);

    float3 L = u.lightDir.xyz;
    float amb = 0.28, kd = 0.95;
    // matte paper never blows out
    float shade = min((amb + kd * max(dot(Nd, L), 0.0)) / (amb + kd * L.z), 1.06);

    // self shadowing from folds, offset along the receiving plane
    float2 gp = float2(0.0);
    float bias = 1.5;
    if (abs(Ng.z) > 0.2) {
        float2 gg = -Ng.xy / Ng.z;
        float den = 1.0 - dot(gg, u.lightK);
        if (abs(den) > 0.25) gp = clamp(gg / den, -3.0, 3.0); else bias = 5.0;
    } else {
        bias = 5.0;
    }
    float sh = shadowAt(in.world, gp, bias, in.position.xy, sm, ss, u);
    shade *= 1.0 - 0.55 * sh;

    return float4(min(col * shade, 1.0), 1.0);
}
"""
