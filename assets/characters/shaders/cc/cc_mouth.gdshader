shader_type spatial;
// Character Creator RLTeethGum and RLTongue in one shader: the parts of the
// mouth, darker and duller the deeper they sit. Built for Godot from CC's
// JSON parameters and its maps.
//
// GradAO is an atlas shared by the upper teeth, lower teeth and tongue;
// each reads a different channel as its front (1) to back (0) gradient
// (checked on the CC bases: upper G, lower R, tongue B).
render_mode sss_mode_skin, cull_back;

uniform sampler2D base_map : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap;
uniform sampler2D ao_map : hint_default_white, filter_linear_mipmap;
uniform sampler2D grad_ao_map : hint_default_white, filter_linear_mipmap;
// White teeth, black gums; the tongue has none and is all soft tissue.
uniform sampler2D gums_mask : hint_default_black, filter_linear_mipmap;
uniform sampler2D micro_normal_map : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec4 grad_channel = vec4(0.0, 1.0, 0.0, 0.0);

uniform float micro_normal_tiling = 10.0;
uniform float micro_normal_strength = 0.3;
uniform bool flip_micro_normal_y = true;
uniform float front_roughness = 0.4;
uniform float back_roughness = 0.0;
uniform float front_specular = 0.1;
uniform float back_specular = 0.0;
uniform float front_ao = 1.0;
uniform float back_ao = 0.0;
uniform float teeth_brightness = 0.7;
uniform float teeth_desaturation = 0.1;
uniform float gums_brightness = 0.9;
uniform float gums_desaturation = 0.0;
uniform float teeth_scatter = 0.5;
uniform float gums_scatter = 1.0;
// The faint warm glow through a tooth's thin edge.
uniform vec3 teeth_edge_color : source_color = vec3(0.31, 0.12, 0.08);

void fragment() {
	float grad = dot(texture(grad_ao_map, UV), grad_channel);
	float teeth = texture(gums_mask, UV).r;
	vec3 col = texture(base_map, UV).rgb;
	float gray = dot(col, vec3(0.299, 0.587, 0.114));
	vec3 tcol = mix(col, vec3(gray), teeth_desaturation) * teeth_brightness;
	vec3 gcol = mix(col, vec3(gray), gums_desaturation) * gums_brightness;
	ALBEDO = mix(gcol, tcol, teeth);

	vec2 n = texture(normal_map, UV).xy * 2.0 - 1.0;
	vec2 m = texture(micro_normal_map, UV * micro_normal_tiling).xy * 2.0 - 1.0;
	if (flip_micro_normal_y) {
		m.y = -m.y;
	}
	n += m * micro_normal_strength;
	NORMAL_MAP = normalize(vec3(n, sqrt(max(0.01, 1.0 - dot(n, n))))) * 0.5 + 0.5;

	// Deep in the mouth there is little light and nothing shines.
	float ao = mix(back_ao, front_ao, grad);
	AO = texture(ao_map, UV).r * ao;
	AO_LIGHT_AFFECT = 1.0 - ao;
	// Rough (dull) at the back, the front's own roughness at the front.
	ROUGHNESS = clamp(mix(1.0, front_roughness, grad), 0.05, 1.0);
	SPECULAR = mix(back_specular, front_specular, grad);
	SSS_STRENGTH = mix(gums_scatter, teeth_scatter, teeth) * grad;
	BACKLIGHT = teeth_edge_color * teeth * grad;
}
