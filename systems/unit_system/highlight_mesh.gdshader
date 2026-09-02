shader_type spatial;

uniform float inner_radius : hint_range(0.0, 1.0) = 0.35;
uniform float outer_radius : hint_range(0.0, 1.0) = 0.45;
uniform vec4 ring_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

void fragment() {
    // PlaneMesh UVs are 0..1, so center them at (0.5, 0.5)
    vec2 centered_uv = UV - vec2(0.5);

    float r = length(centered_uv);

    // Kill pixels outside the ring band
    if (r < inner_radius || r > outer_radius) {
        discard;
    }

    ALBEDO = ring_color.rgb;
    ALPHA = ring_color.a;
}
