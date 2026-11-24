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
uniform float roughness_offset = 0.0;
uniform float unmasked_scatter_scale = 1.0;
// CC's "_Specular": 0.5 is the usual 4% dielectric, as Godot's SPECULAR.
uniform float specular = 0.4;
// CC's subsurface falloff colour, used for light through the ears.
uniform vec3 scatter_color : source_color = vec3(1.0, 0.37, 0.3);
// Kept low: Godot's screen-space scatter blurs the lit skin, and much more
// than this wipes the pores off a face.
uniform float sss_strength = 0.08;
uniform float transmission_strength = 0.2;
// Light that scatters under skin comes back redder. Godot's screen-space
// scatter only blurs the lighting, so the colour shift is done in light():
// direct light on scattering skin is multiplied by this tint...
uniform vec3 scatter_tint : source_color = vec3(1.0);
// ...and wraps past the shadow line, each channel by its share of the
// scatter colour, so the terminator turns red before it turns dark.
uniform float scatter_wrap = 0.35;
uniform vec3 shadow_bleed = vec3(0.6, 1.2, 1.5);
// The red edge is tuned for a light of about this energy. Under a brighter
// light the edge is pushed past what the tonemapper can hold and clips to
// crimson, so its colour fades toward neutral by the excess. 0 switches the
// fade off.
uniform float scatter_energy_ref = 0.0;
// The colour map is a touch too light and flat for a lit surface: it is
// darkened by this gamma, and creases (the occlusion map) darken the colour
// itself, at ao_colour strength, so they hold under direct light.
uniform float colour_gamma = 1.1;
uniform float ao_colour = 0.5;
varying float v_scatter;
varying float v_transmit;
varying float v_f0;
// How much of the smoothness map shapes roughness; the rest sits at a flat mid value.
uniform float roughness_map_weight = 0.25;
// Reflectance at normal incidence for full-mask skin.
uniform float skin_f0 = 0.028;

// The character's skin tint, per instance so one material serves everyone.
// Slot 1: slot 0 is the outline pass's outline_color (outline_pass.gdshader).
instance uniform vec3 skin_tint : source_color, instance_index(1) = vec3(1.0);

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
// The lids sit in the brow's shadow, too fine a fold for the shadow map:
// the upper and inner lid masks darken the skin by this much instead.
uniform float lid_shade = 0.4;
#else
// The body's R, G, B, A areas.
uniform sampler2D rgba_mask : hint_default_black, filter_linear_mipmap;
uniform vec4 rgba_roughness = vec4(0.0);
uniform vec4 rgba_scatter = vec4(1.0);
// The skin under what the character wears, as bits over the body skin's
// binds (bind i is bit i % 32 of word i / 32): CCLook.wear() sets it from
// the worn items' Wearable.hides. A vertex is hidden when most of its weight
// lies on hidden binds, and its skin is not drawn, so it cannot poke through.
// The binds come from CUSTOM0 (the vertex's four heaviest bind indices) and
// CUSTOM1 (their weights), which CCMaterials puts on the body mesh: Forward+
// skins on the GPU before vertex() runs, so BONE_INDICES and BONE_WEIGHTS
// read as zero here.
instance uniform ivec4 hidden_binds : instance_index(2) = ivec4(0);
varying float v_hidden;

void vertex() {
	v_hidden = 0.0;
	for (int i = 0; i < 4; i++) {
		int b = int(CUSTOM0[i] + 0.5);
		if (b < 128 && ((hidden_binds[b / 32] >> (b % 32)) & 1) != 0) {
			v_hidden += CUSTOM1[i];
		}
	}
}
#endif

// A tangent-space normal from a two-channel (or three-channel) map; the
// RGTC-compressed maps carry no blue, so z is rebuilt.
vec2 unpack_xy(vec4 t) {
	return t.xy * 2.0 - 1.0;
}

void fragment() {
#ifndef CC_HEAD
	if (v_hidden > 0.5) {
		discard;
	}
#endif
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
	float rough = mix(0.5, (1.0 - hdrp.a) * original_roughness_strength, roughness_map_weight) + micro_roughness_scale * micro;
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
	v_f0 = skin_f0 * (specular / 0.4) * texture(spec_mask, uv).r;
	SPECULAR = sqrt(v_f0 / 0.16);
#else
	vec4 r = texture(rgba_mask, uv);
	float covered = clamp(dot(r, vec4(1.0)), 0.0, 1.0);
	rough += dot(r, rgba_roughness) + (1.0 - covered) * unmasked_roughness_scale;
	scatter = dot(r, rgba_scatter) + (1.0 - covered) * unmasked_scatter_scale;
	v_f0 = skin_f0 * (specular / 0.4);
	SPECULAR = sqrt(v_f0 / 0.16);
#endif
	// Rougher at grazing angles, as skin's fine fuzz is.
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	rough += edge_roughness_multiplier * (1.0 - facing) + roughness_offset;

	ALBEDO = pow(albedo, vec3(colour_gamma)) * mix(1.0, ao * ao, ao_colour);
#ifdef CC_HEAD
	ALBEDO *= 1.0 - lid_shade * clamp(b.b + b.a, 0.0, 1.0);
#endif
	v_scatter = clamp(scatter, 0.0, 1.0);
	ROUGHNESS = clamp(rough, 0.05, 1.0);
	AO = ao;
	SSS_STRENGTH = sss_strength * texture(sss_map, uv).r * scatter;
	v_transmit = texture(transmission_map, uv).r * transmission_strength;
}

void light() {
	float ndl = dot(NORMAL, LIGHT);
	float keep = 1.0;
	if (scatter_energy_ref > 0.0) {
		keep = min(1.0, scatter_energy_ref * PI / max(dot(LIGHT_COLOR, vec3(0.2126, 0.7152, 0.0722)), 1e-4));
	}
	vec3 sc = mix(vec3(dot(scatter_color, vec3(1.0 / 3.0))), scatter_color, keep);
	vec3 w = sc * scatter_wrap * v_scatter;
	vec3 diff = clamp((vec3(ndl) + w) / (1.0 + w), 0.0, 1.0);
	// Thin parts (ears, nostrils) let light through from behind.
	diff += scatter_color * v_transmit * clamp(-ndl, 0.0, 1.0);
	vec3 tint = mix(vec3(1.0), scatter_tint, v_scatter);
	// Light scattered under the skin carries red a little way into a cast
	// shadow, so the shadow's edge fades through red rather than grey.
	vec3 shade = vec3(ATTENUATION);
	if (LIGHT_IS_DIRECTIONAL) {
		shade = pow(shade, mix(vec3(1.0), shadow_bleed, v_scatter * keep));
	}
	DIFFUSE_LIGHT += diff * tint * shade * LIGHT_COLOR / PI;

	// Specular: GGX with a Schlick fresnel.
	vec3 h = normalize(VIEW + LIGHT);
	float nl = clamp(ndl, 0.0, 1.0);
	float nv = max(dot(NORMAL, VIEW), 1e-4);
	float nh = clamp(dot(NORMAL, h), 0.0, 1.0);
	float a = ROUGHNESS * ROUGHNESS;
	float a2 = a * a;
	float dd = nh * nh * (a2 - 1.0) + 1.0;
	float D = a2 / (PI * dd * dd);
	float vis = 0.5 / max(nl * sqrt(nv * nv * (1.0 - a2) + a2) + nv * sqrt(nl * nl * (1.0 - a2) + a2), 1e-4);
	float f0 = v_f0;
	float F = f0 + (1.0 - f0) * pow(1.0 - clamp(dot(VIEW, h), 0.0, 1.0), 5.0);
	SPECULAR_LIGHT += D * vis * F * nl * ATTENUATION * LIGHT_COLOR / PI * SPECULAR_AMOUNT;
}
