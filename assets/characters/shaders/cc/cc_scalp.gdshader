shader_type spatial;
// The scalp layer under CC hair (its "Scalp" or "Clap" material): hair
// colour painted on a cap around the head, faded out by an opacity map so
// the hairline blends into the skin. Base colour and opacity only, as CC's
// JSON gives it.
render_mode cull_back, depth_draw_never, blend_mix, shadows_disabled;

uniform sampler2D base_map : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D opacity_map : hint_default_white, filter_linear_mipmap;

// The hair's colour override (see cc_hair.gdshaderinc), applied the same way.
instance uniform vec4 hair_color = vec4(0.0);
uniform vec3 ref_color : source_color = vec3(0.3, 0.25, 0.22);

void fragment() {
	vec3 col = texture(base_map, UV).rgb;
	if (hair_color.a > 0.0) {
		float l = dot(col, vec3(0.299, 0.587, 0.114));
		float ref = max(dot(ref_color, vec3(0.299, 0.587, 0.114)), 0.002);
		col = mix(col, hair_color.rgb * clamp(l / ref, 0.0, 3.0), hair_color.a);
	}
	ALBEDO = col;
	ROUGHNESS = 0.8;
	SPECULAR = 0.2;
	ALPHA = texture(opacity_map, UV).r;
}
