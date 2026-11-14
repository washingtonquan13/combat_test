shader_type spatial;
render_mode sss_mode_skin, cull_back;

// Skin for the baked MPFB humans. Their skins are a single diffuse map, so
// everything else is made here: subsurface scattering and light through
// thin parts (ears, nostrils), pores from a tiling detail normal, a darkening
// in creases read from the diffuse map itself, roughness that varies, and a
// faint fuzz at grazing angles.

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec4 tint : source_color = vec4(1.0);

// Pores: a tiling normal map repeated across the body's UVs.
uniform sampler2D pore_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float pore_scale = 60.0;
uniform float pore_strength : hint_range(0.0, 2.0) = 0.4;

uniform float roughness_base : hint_range(0.0, 1.0) = 0.5;
// How much the pores and creases move roughness about.
uniform float roughness_variation : hint_range(0.0, 0.5) = 0.15;
// 0.5 is Godot's default (4% reflectance); skin is nearer 2.8%.
uniform float specular_level : hint_range(0.0, 1.0) = 0.4;

uniform float subsurface : hint_range(0.0, 1.0) = 0.5;
uniform vec4 transmittance_color : source_color = vec4(0.85, 0.3, 0.2, 1.0);
uniform float transmittance_depth : hint_range(0.0, 1.0) = 0.12;
uniform float transmittance_boost : hint_range(0.0, 1.0) = 0.1;

// Creases (lids, lips, nostrils, nails) are darker than their surroundings
// in the diffuse map; this deepens that difference as occlusion.
uniform float cavity : hint_range(0.0, 2.0) = 0.8;
uniform float cavity_mip = 5.0;

uniform float fuzz : hint_range(0.0, 1.0) = 0.15;

// Where hair grows: the scalp under the hair cards, grown with them by
// tools/characters/groom.py (white where hair roots are). The skin there is
// tinted towards the hair and made rougher, so gaps between cards show
// rooted hair rather than bare skin.
uniform sampler2D scalp_texture : hint_default_black, filter_linear_mipmap, repeat_disable;
uniform vec4 scalp_color : source_color = vec4(0.25, 0.17, 0.11, 1.0);
uniform float scalp_strength : hint_range(0.0, 1.0) = 0.95;
uniform float fuzz_tint : hint_range(0.0, 1.0) = 0.7;

float luma(vec3 c) {
	return dot(c, vec3(0.299, 0.587, 0.114));
}

void fragment() {
	vec3 albedo = texture(albedo_texture, UV).rgb * tint.rgb;
	vec3 around = textureLod(albedo_texture, UV, cavity_mip).rgb * tint.rgb;
	float crease = clamp(luma(albedo) / max(luma(around), 0.001), 0.0, 1.0);
	float occlusion = pow(crease, cavity);

	vec3 pore = texture(pore_normal, UV * pore_scale).rgb;
	float pore_height = pore.b * 2.0 - 1.0;

	float scalp = texture(scalp_texture, UV).r * scalp_strength;
	// Under hair the scalp sits in the hair's shadow, so darker than the hair.
	albedo = mix(albedo, scalp_color.rgb * 0.3, scalp);
	occlusion *= 1.0 - scalp * 0.5;

	ALBEDO = albedo;
	AO = occlusion;
	AO_LIGHT_AFFECT = mix(0.25, 0.6, scalp);
	NORMAL_MAP = pore;
	NORMAL_MAP_DEPTH = pore_strength;
	ROUGHNESS = clamp(roughness_base + roughness_variation * ((1.0 - crease) * 2.0 - (1.0 - pore_height)), 0.2, 1.0);
	ROUGHNESS = mix(ROUGHNESS, 0.85, scalp);
	// Hair takes the skin's sheen: no glancing shine or fuzz under it.
	SPECULAR = specular_level * (1.0 - scalp);
	SSS_STRENGTH = subsurface * (1.0 - scalp * 0.7);
	SSS_TRANSMITTANCE_COLOR = transmittance_color;
	SSS_TRANSMITTANCE_DEPTH = transmittance_depth;
	SSS_TRANSMITTANCE_BOOST = transmittance_boost;
	RIM = fuzz * (1.0 - scalp);
	RIM_TINT = fuzz_tint;
}
