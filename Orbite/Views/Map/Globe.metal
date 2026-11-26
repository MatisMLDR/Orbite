#include <metal_stdlib>
using namespace metal;

/// Mirrors GlobeUniforms in GlobeSurface.swift, field for field.
struct GlobeUniforms {
    float4 glow;        // atmosphere colour, straight alpha
    float4 ocean;       // surface colour until the map texture arrives
    float4 sun;         // xyz: unit vector towards the light, Earth-fixed (x: 0°E, y: 90°E, z: north)
    float4 night;       // rgb: what the night side keeps of the map's colours; a: 1 day and night, 0 always day
    float2 center;      // globe centre, in drawable pixels
    float radius;       // in drawable pixels
    float latitude;     // point in the middle of the view, radians
    float longitude;
    float lod;          // texture level for the globe's size on screen
    float hasTexture;
};

struct GlobeVertex {
    float4 position [[position]];
};

/// One triangle that covers the whole view.
vertex GlobeVertex globeVertex(uint id [[vertex_id]]) {
    float2 corner = float2((id << 1) & 2, id & 2);
    GlobeVertex out;
    out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

/// Orthographic globe: each pixel of the disc goes back to its latitude and longitude and reads the
/// equirectangular Plan texture there. Same projection as GlobeProjection in GeoMath.swift.
/// Lit by the real sun when the day-night cycle is on (day side, a warm dusk along the terminator, a dim
/// blue night); otherwise by a fixed light, in the Plan's colours everywhere.
fragment half4 globeFragment(GlobeVertex in [[stage_in]],
                             constant GlobeUniforms &u [[buffer(0)]],
                             texture2d<half> earth [[texture(0)]]) {
    float2 d = (in.position.xy - u.center) / u.radius;
    d.y = -d.y;
    float rho = length(d);
    float pixel = 1.0 / u.radius;

    float sinLat = sin(u.latitude), cosLat = cos(u.latitude);
    float sinLon = sin(u.longitude), cosLon = cos(u.longitude);
    float3 out = float3(cosLat * cosLon, cosLat * sinLon, sinLat);
    float3 east = float3(-sinLon, cosLon, 0.0);
    float3 north = float3(-sinLat * cosLon, -sinLat * sinLon, cosLat);
    float3 sun = u.sun.xyz;

    // Atmosphere: a thin halo fading out from the rim, bright where the sun shines on it.
    half4 color = half4(0.0);
    if (rho > 1.0 - pixel) {
        float3 rim = normalize(d.x * east + d.y * north + 1e-6 * out);
        float sunlit = mix(1.0, smoothstep(-0.35, 0.45, dot(rim, sun)), u.night.a);
        float a = u.glow.a * (0.25 + 0.75 * sunlit) * exp(-max(rho - 1.0, 0.0) / 0.05);
        color = half4(half3(u.glow.rgb) * half(a), half(a));
    }
    if (rho >= 1.0 + pixel) {
        return color;
    }

    float z = sqrt(max(0.0, 1.0 - rho * rho));
    float3 w = d.x * east + d.y * north + z * out;

    half3 surface = half3(u.ocean.rgb);
    if (u.hasTexture > 0.5) {
        float latitude = asin(clamp(w.z, -1.0, 1.0));
        float longitude = atan2(w.y, w.x);
        float2 uv = float2(longitude / (2.0 * M_PI_F) + 0.5, 0.5 - latitude / M_PI_F);
        constexpr sampler s(s_address::repeat, t_address::clamp_to_edge,
                            mag_filter::linear, min_filter::linear, mip_filter::linear);
        // Explicit level: the seam at ±180° would otherwise pick the blurriest one.
        surface = earth.sample(s, uv, level(u.lod)).rgb;
    }

    // Sunlight: brightest under the sun, a soft terminator about 6° wide, a warm band at dusk.
    float elevation = dot(w, sun);
    float day = mix(1.0, smoothstep(-0.10, 0.06, elevation), u.night.a);
    half3 lit = surface * half(0.80 + 0.22 * clamp(elevation, 0.0, 1.0));
    float dusk = (1.0 - smoothstep(0.0, 0.14, abs(elevation + 0.01))) * u.night.a;
    lit = mix(lit, lit * half3(1.06, 0.88, 0.74), half(0.35 * dusk));
    half3 shaded = mix(surface * half3(u.night.rgb), lit, half(day));

    // A darker rim: the disc reads as a sphere on the night side too.
    shaded *= half(1.0 - 0.10 * pow(1.0 - z, 3.0));
    float edge = clamp((1.0 - rho) / pixel + 0.5, 0.0, 1.0);
    half4 globe = half4(shaded, 1.0) * half(edge);
    return globe + color * (1.0h - globe.a);
}
