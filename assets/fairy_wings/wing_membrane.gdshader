// Gossamer wing membrane: a faint tint that thickens toward the rim and the
// veins, with a thin-film sheen that shifts hue with the viewing angle.
// UV.x runs root (0) to tip (1); UV.y trailing edge (0) to leading (1).
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque, specular_schlick_ggx;

uniform vec4 tint : source_color = vec4(0.78, 0.93, 1.0, 1.0);
uniform vec4 vein_color : source_color = vec4(0.55, 0.75, 0.95, 1.0);
uniform float membrane_alpha : hint_range(0.0, 1.0) = 0.18;
uniform float vein_alpha : hint_range(0.0, 1.0) = 0.65;
uniform float rim_width : hint_range(0.0, 0.3) = 0.06;
uniform float veins : hint_range(1.0, 12.0) = 6.0;
uniform float sheen : hint_range(0.0, 2.0) = 0.9;
uniform float glow : hint_range(0.0, 2.0) = 0.25;

float line(float x, float w) {
	float d = abs(fract(x) - 0.5) * 2.0;
	return smoothstep(1.0 - w, 1.0, d);
}

vec3 film(float t) {
	return 0.5 + 0.5 * cos(6.2832 * (t + vec3(0.0, 0.33, 0.67)));
}

void fragment() {
	vec2 uv = UV;
	float across = abs(uv.y * 2.0 - 1.0);
	float edge = max(across, smoothstep(0.8, 1.0, uv.x));
	float rim = smoothstep(1.0 - rim_width * 2.0, 1.0, edge);
	// Veins fan out from the root, with a couple of cross veins.
	float radial = line(uv.y * veins + 0.5, 0.08 + 0.1 * (1.0 - uv.x)) * smoothstep(0.02, 0.15, uv.x);
	float cross = line(uv.x * 2.5, 0.05) * (1.0 - across);
	float vein = max(radial, cross * 0.7);
	float facing = abs(dot(NORMAL, VIEW));
	float fres = pow(1.0 - facing, 2.0);
	vec3 col = mix(tint.rgb, vein_color.rgb, max(vein, rim));
	col += film(fres * 1.3 + uv.x * 0.4) * sheen * fres;
	ALBEDO = col;
	EMISSION = col * glow;
	ROUGHNESS = 0.25;
	SPECULAR = 0.6;
	ALPHA = clamp(membrane_alpha + fres * 0.35 + max(vein * vein_alpha, rim * 0.8) * 0.8, 0.0, 0.95);
}
