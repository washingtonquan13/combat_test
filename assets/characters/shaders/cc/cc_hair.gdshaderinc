// Shared by cc_hair (solid pass) and cc_hair_fringe (blended strand ends).
// HAIR_SURFACE(uv) writes ALBEDO, ROUGHNESS, SPECULAR, AO, ANISOTROPY and
// BACKLIGHT in fragment() (functions cannot write built-ins).

uniform sampler2D opacity_map : hint_default_white, filter_linear_mipmap_anisotropic;
uniform sampler2D root_map : hint_default_black, filter_linear_mipmap;
uniform sampler2D id_map : hint_default_black, filter_linear_mipmap;
uniform sampler2D flow_map : hint_normal, filter_linear_mipmap;
uniform sampler2D blend_map : hint_default_white, filter_linear_mipmap;
uniform sampler2D orm_map : hint_default_white, filter_linear_mipmap;

uniform vec3 root_color : source_color = vec3(0.03, 0.02, 0.01);
uniform vec3 tip_color : source_color = vec3(0.1, 0.07, 0.05);
uniform bool invert_root_tip = false;
uniform float diffuse_strength = 1.0;
uniform float blend_map_strength = 0.7;
// Each dye: colour, strength, the ID-map range it covers (low, peak, high, 0-1)
// and whether the root map limits it to the tips (1), the roots (-1) or not (0).
uniform vec3 dye1_color : source_color = vec3(0.0);
uniform float dye1_strength = 0.0;
uniform vec3 dye1_range = vec3(0.0, 1.0, 1.0);
uniform float dye1_root_mask = 0.0;
uniform vec3 dye2_color : source_color = vec3(0.0);
uniform float dye2_strength = 0.0;
uniform vec3 dye2_range = vec3(0.0, 1.0, 1.0);
uniform float dye2_root_mask = 0.0;

uniform float specular_strength = 0.35;
// CC's Specular Strength scales its own hair lobe; used as Godot's SPECULAR
// (F0) on flat cards it turns near-black hair grey with white glints, because
// card normals are not strand normals. This brings it to CC's look.
uniform float specular_scale = 0.3;
uniform float spec_map_strength = 0.25;
uniform float roughness_map_strength = 0.5;
uniform float anisotropy = 0.8;
uniform bool flip_flow_y = true;
uniform float transmission = 0.5;

// This character's hair colour. Alpha 0 keeps CC's colours; above 0 the
// hair takes this colour, keeping its strand-to-strand light and dark.
instance uniform vec4 hair_color = vec4(0.0);

float dye_weight(float id, vec3 range, float root, float root_mask) {
	float up = range.y > range.x ? smoothstep(range.x, range.y, id) : step(range.x, id);
	float down = range.z > range.y ? 1.0 - smoothstep(range.y, range.z, id) : 1.0;
	float w = up * down;
	if (root_mask > 0.5) {
		w *= root;
	} else if (root_mask < -0.5) {
		w *= 1.0 - root;
	}
	return w;
}

float luma(vec3 c) {
	return dot(c, vec3(0.299, 0.587, 0.114));
}

float hair_alpha(vec2 uv) {
	return texture(opacity_map, uv).r;
}

struct Hair {
	vec3 albedo;
	float ao;
	float roughness;
	float specular;
	vec2 flow;
};

Hair hair_surface(vec2 uv) {
	Hair h;
	float root = texture(root_map, uv).r;
	if (invert_root_tip) {
		root = 1.0 - root;
	}
	float id = texture(id_map, uv).r;
	vec3 col = mix(root_color, tip_color, root);
	col = mix(col, dye1_color, dye_weight(id, dye1_range, root, dye1_root_mask) * dye1_strength);
	col = mix(col, dye2_color, dye_weight(id, dye2_range, root, dye2_root_mask) * dye2_strength);
	if (hair_color.a > 0.0) {
		float ref = max(luma(mix(root_color, tip_color, 0.5)), 0.002);
		col = mix(col, hair_color.rgb * clamp(luma(col) / ref, 0.0, 3.0), hair_color.a);
	}
	col *= mix(1.0, texture(blend_map, uv).r, blend_map_strength);
	h.albedo = clamp(col * diffuse_strength, 0.0, 1.0);

	vec3 orm = texture(orm_map, uv).rgb;
	h.ao = orm.r;
	h.roughness = clamp(mix(0.5, orm.g, roughness_map_strength), 0.15, 1.0);
	h.specular = specular_strength * specular_scale * mix(1.0, 0.5 + id, spec_map_strength);

	vec2 flow = texture(flow_map, uv).rg * 2.0 - 1.0;
	if (flip_flow_y) {
		flow.y = -flow.y;
	}
	h.flow = length(flow) > 0.01 ? normalize(flow) : vec2(1.0, 0.0);
	return h;
}

// Light through thin hair is in the hair's own colour.
#define HAIR_SURFACE(uv) Hair h = hair_surface(uv); ALBEDO = h.albedo; AO = h.ao; AO_LIGHT_AFFECT = 1.0; ROUGHNESS = h.roughness; SPECULAR = h.specular; ANISOTROPY = anisotropy; ANISOTROPY_FLOW = h.flow; BACKLIGHT = h.albedo * transmission
