shader_type spatial;
render_mode unshaded, depth_draw_opaque, cull_back;

group_uniforms Grease;

uniform vec4 base_color : source_color = vec4(0.25, 0.18, 0.12, 1.0);
uniform float swirl_strength = 0.15;
uniform float swirl_speed = 0.15;

uniform float ripple_strength = 0.03;
uniform float ripple_speed = 0.4;

uniform float depth_tint_strength = 0.45;

uniform float specular_strength = 0.6;
uniform float specular_softness = 8.0;

uniform sampler2D swirl_tex;   // large-scale swirl noise
uniform sampler2D ripple_tex;  // fine ripple noise
uniform sampler2D normal_tex;  // optional normal map

void fragment() {
    float t = TIME;

    // --- LARGE SWIRLS (slow, thick motion)
    vec2 swirl_uv = UV * 2.0 + vec2(t * swirl_speed * 0.1, t * swirl_speed * 0.07);
    float swirl = texture(swirl_tex, swirl_uv).r;

    // --- SMALL RIPPLES (fast micro motion)
    vec2 ripple_uv = UV * 8.0 + vec2(t * ripple_speed * 0.3, t * ripple_speed * 0.2);
    float ripple = texture(ripple_tex, ripple_uv).r;

    // --- Combine displacement
    float displacement = swirl * swirl_strength + ripple * ripple_strength;

    // --- Depth tinting (thicker areas look darker)
    vec3 color = base_color.rgb;
    color *= mix(1.0, 0.55, swirl * depth_tint_strength);

    // --- Normal map (optional)
    vec3 n = texture(normal_tex, UV).rgb * 2.0 - 1.0;
    n = normalize(n);

    // --- Soft specular highlight
    vec3 L = normalize(vec3(0.3, 0.7, 0.4)); // fake light
    vec3 V = normalize(-NORMAL);
    vec3 H = normalize(L + V);

    float spec = pow(max(dot(n, H), 0.0), specular_softness) * specular_strength;

    // --- Final color
    ALBEDO = color + vec3(spec);
    ALPHA = base_color.a;
}
