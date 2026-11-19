// Character Creator skin (RLSkin, and RLHead when CC_HEAD is defined),
// written for Godot from the parameters CC exports in its JSON sidecar and
// from what its maps hold. Not a translation of any other port's graphs.
// CCMaterials (assets/characters/cc_materials.gd) fills every uniform.
//
// The body's UVs are UDIM tiles (body 1-2, arm 2-3, ...), so every map is
// read at fract(UV).
render_mode sss_mode_skin, cull_back;

uniform sampler2D base_map : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D ao_map : hint_default_white, filter_linear_mipmap;
// R metallic, G AO, B detail mask, A smoothness.
uniform sampler2D hdrp_map : hint_default_white, filter_linear_mipmap;
uniform sampler2D sss_map : hint_default_white, filter_linear_mipmap;
// Thin parts light shows through: ears, nostrils.
uniform sampler2D transmission_map : hint_default_black, filter_linear_mipmap;
uniform sampler2D micro_normal_map : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D micro_normal_mask : hint_default_white, filter_linear_mipmap;

uniform float micro_normal_tiling = 25.0;
uniform float micro_normal_strength = 0.8;
uniform bool flip_micro_normal_y = true;
uniform float original_roughness_strength = 0.85;
uniform float micro_roughness_scale = 0.055;
uniform float edge_roughness_multiplier = 0.044;
uniform float unmasked_roughness_scale = 0.0;
// Not CC's: a Godot-side tune. Godot lights skin with one sharp specular
// lobe; this dulls it toward the softer sheen CC shows.
uniform float roughness_offset = 0.15;
uniform float unmasked_scatter_scale = 1.0;
// CC's "_Specular": 0.5 is the usual 4% dielectric, as Godot's SPECULAR.
uniform float specular = 0.4;
// CC's subsurface falloff colour, used for light through the ears.
uniform vec3 scatter_color : source_color = vec3(1.0, 0.37, 0.3);
uniform float sss_strength = 1.0;
uniform float transmission_strength = 0.2;

// The character's skin tint, per instance so one material serves everyone.
instance uniform vec3 skin_tint : source_color = vec3(1.0);

#ifdef CC_HEAD
uniform sampler2D spec_mask : hint_default_white, filter_linear_mipmap;
// R cheek, G forehead, B upper lip, A chin.
uniform sampler2D cfulc_mask : hint_default_black, filter_linear_mipmap;
// R nose, G mouth, B upper lid, A inner lid.
uniform sampler2D nmuil_mask : hint_default_black, filter_linear_mipmap;
// Ear and neck, in the order CC names them.
uniform sampler2D en_mask : hint_default_black, filter_linear_mipmap;
// White is open; R inner mouth, G nostrils, B the gap between the lips.
uniform sampler2D cavity_mask : hint_default_white, filter_linear_mipmap;
uniform vec4 cfulc_roughness = vec4(0.0);
uniform vec4 nmuil_roughness = vec4(0.0);
uniform vec2 en_roughness = vec2(0.0);
uniform vec4 cfulc_scatter = vec4(1.0);
uniform vec4 nmuil_scatter = vec4(1.0);
uniform vec2 en_scatter = vec2(1.0);
// Inner mouth, nostril, lips gap: how hard each cavity darkens.
uniform vec3 cavity_ao = vec3(2.5, 3.5, 2.5);
#else
// The body's R, G, B, A areas.
uniform sampler2D rgba_mask : hint_default_black, filter_linear_mipmap;
uniform vec4 rgba_roughness = vec4(0.0);
uniform vec4 rgba_scatter = vec4(1.0);
#endif

// A tangent-space normal from a two-channel (or three-channel) map; the
// RGTC-compressed maps carry no blue, so z is rebuilt.
vec2 unpack_xy(vec4 t) {
	return t.xy * 2.0 - 1.0;
}

void fragment() {
	vec2 uv = fract(UV);
	vec3 albedo = texture(base_map, uv).rgb * skin_tint;
	vec4 hdrp = texture(hdrp_map, uv);
	float ao = texture(ao_map, uv).r;

	// Normal: the base map plus the tiled pore detail, masked off the brows,
	// nose and lips.
	vec2 n = unpack_xy(texture(normal_map, uv));
	vec2 m = unpack_xy(texture(micro_normal_map, uv * micro_normal_tiling));
	if (flip_micro_normal_y) {
		m.y = -m.y;
	}
	float micro = texture(micro_normal_mask, uv).r;
	n += m * micro_normal_strength * micro;
	float nz = sqrt(max(0.0, 1.0 - dot(n, n)));
	vec3 nn = normalize(vec3(n, max(nz, 0.1)));
	NORMAL_MAP = nn * 0.5 + 0.5;

	// Roughness: the map's, scaled, with pores a touch rougher and each
	// region nudged by its own scale.
	float rough = (1.0 - hdrp.a) * original_roughness_strength + micro_roughness_scale * micro;
	float scatter;
#ifdef CC_HEAD
	vec4 a = texture(cfulc_mask, uv);
	vec4 b = texture(nmuil_mask, uv);
	vec2 c = texture(en_mask, uv).rg;
	float covered = clamp(dot(a, vec4(1.0)) + dot(b, vec4(1.0)) + c.x + c.y, 0.0, 1.0);
	rough += dot(a, cfulc_roughness) + dot(b, nmuil_roughness) + dot(c, en_roughness)
			+ (1.0 - covered) * unmasked_roughness_scale;
	scatter = dot(a, cfulc_scatter) + dot(b, nmuil_scatter) + dot(c, en_scatter)
			+ (1.0 - covered) * unmasked_scatter_scale;
	vec3 cav = texture(cavity_mask, uv).rgb;
	float cavity = pow(cav.r, cavity_ao.x) * pow(cav.g, cavity_ao.y) * pow(cav.b, cavity_ao.z);
	ao *= cavity;
	// Cavities shut out direct light too; open skin keeps it.
	AO_LIGHT_AFFECT = 1.0 - cavity;
	SPECULAR = specular * texture(spec_mask, uv).r;
#else
	vec4 r = texture(rgba_mask, uv);
	float covered = clamp(dot(r, vec4(1.0)), 0.0, 1.0);
	rough += dot(r, rgba_roughness) + (1.0 - covered) * unmasked_roughness_scale;
	scatter = dot(r, rgba_scatter) + (1.0 - covered) * unmasked_scatter_scale;
	SPECULAR = specular;
#endif
	// Rougher at grazing angles, as skin's fine fuzz is.
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	rough += edge_roughness_multiplier * (1.0 - facing) + roughness_offset;

	ALBEDO = albedo;
	ROUGHNESS = clamp(rough, 0.05, 1.0);
	AO = ao;
	SSS_STRENGTH = sss_strength * texture(sss_map, uv).r * scatter;
	BACKLIGHT = scatter_color * texture(transmission_map, uv).r * transmission_strength;
}
