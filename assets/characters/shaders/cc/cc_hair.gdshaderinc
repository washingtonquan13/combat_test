// Shared by cc_hair (solid pass) and cc_hair_fringe (blended strand ends).
// HAIR_SURFACE(uv) writes ALBEDO, ROUGHNESS, SPECULAR, AO, ANISOTROPY and the
// light() varyings in fragment() (functions cannot write built-ins).
//
// Colour, as CC's Smart Hair stacks it: a base (the blend map at its Base
// Color strength), the strand's root-to-end colour blended onto it, then two
// highlight dyes picked by the ID map, each with its own blend mode (0 Normal,
// 1 Multiply, 2 Overlay, 3 Soft Light; blended in gamma space, as a paint
// program does). The vertex colour (its G channel, a grey per card layer)
// darkens inner layers last.
//
// Light: light() replaces Godot's lobe with two strand highlights along the
// flow map (Kajiya-Kay): a white primary, and a broader secondary tinted by
// the hair's colour, shifted apart along the strand. CC's reflection offsets
// (by black ID and by white ID, mixed by the ID map) nudge the flow's red and
// green (CC's "Rotate Vertical/Horizontal") and the shift. Light from behind
// passes through as transmission. Ambient reflections stay Godot's, bent
// along the strand by ANISOTROPY.

uniform sampler2D opacity_map : hint_default_white, filter_linear_mipmap_anisotropic;
uniform sampler2D root_map : hint_default_black, filter_linear_mipmap;
uniform sampler2D id_map : hint_default_black, filter_linear_mipmap;
uniform sampler2D flow_map : hint_normal, filter_linear_mipmap;
uniform sampler2D blend_map : hint_default_white, filter_linear_mipmap;
uniform sampler2D orm_map : hint_default_white, filter_linear_mipmap;

// The base: the blend map's strength over white.
uniform float blend_map_strength = 0.7;
// Root-to-end strand colour: colours, how it blends onto the base, its
// global, root and end strengths, and how far root and end are swapped (0-1).
uniform vec3 root_color : source_color = vec3(0.03, 0.02, 0.01);
uniform vec3 tip_color : source_color = vec3(0.1, 0.07, 0.05);
uniform int strand_blend_mode = 1;
uniform float strand_strength = 1.0;
uniform float root_strength = 1.0;
uniform float tip_strength = 1.0;
uniform float invert_root_tip = 0.0;
uniform float diffuse_strength = 1.0;
// Vertex colour: a card layer's grey runs from this colour (black) to white.
uniform vec3 vertex_gray_color : source_color = vec3(0.0);
uniform float vertex_color_strength = 0.0;

// Each dye: colour, strength, blend mode, the ID-map range it covers (low,
// peak, high, 0-1), how far it is kept off the strand ends ("Overlap End
// Color", 0-1), whether that end mask is turned to the roots ("Invert", 0-1),
// and how much shine it adds.
uniform bool dyes_active = true;
uniform vec3 dye1_color : source_color = vec3(0.0);
uniform float dye1_strength = 0.0;
uniform int dye1_blend_mode = 0;
uniform vec3 dye1_range = vec3(0.0, 1.0, 1.0);
uniform float dye1_end_overlap = 0.0;
uniform float dye1_end_invert = 0.0;
uniform float dye1_specular = 0.0;
uniform vec3 dye2_color : source_color = vec3(0.0);
uniform float dye2_strength = 0.0;
uniform int dye2_blend_mode = 0;
uniform vec3 dye2_range = vec3(0.0, 1.0, 1.0);
uniform float dye2_end_overlap = 0.0;
uniform float dye2_end_invert = 0.0;
uniform float dye2_specular = 0.0;

uniform float specular_strength = 0.35;
uniform float secondary_specular_strength = 0.5;
uniform float spec_map_strength = 0.25;
uniform float roughness_map_strength = 0.5;
// Reflection offsets for black-ID and white-ID strands: (flow red, flow
// green, shift).
uniform vec3 black_offset = vec3(0.0);
uniform vec3 white_offset = vec3(0.0);
uniform float anisotropy = 0.8;
uniform bool flip_flow_y = true;
uniform float transmission = 0.5;
// Godot-side tunes. CC's Specular Strength used as Godot's SPECULAR (F0) on
// flat cards turned near-black hair grey with white glints (card normals are
// not strand normals), so the ambient reflection takes it scaled down.
// highlight_gain scales both strand highlights; the shifts set how far the
// primary and secondary sit apart along the strand.
uniform float specular_scale = 0.3;
uniform float highlight_gain = 1.0;
uniform float primary_shift = 0.05;
uniform float secondary_shift = -0.1;

// This character's hair colour. Alpha 0 keeps CC's colours; above 0 the
// hair takes this colour, keeping its strand-to-strand light and dark.
instance uniform vec4 hair_color = vec4(0.0);

varying vec3 v_strand;
varying float v_shift;
varying float v_primary;
varying float v_secondary;

float dye_weight(float id, vec3 range, float root, float overlap, float invert) {
	float up = range.y > range.x ? smoothstep(range.x, range.y, id) : step(range.x, id);
	float down = range.z > range.y ? 1.0 - smoothstep(range.y, range.z, id) : 1.0;
	float end = mix(root, 1.0 - root, invert);
	return up * down * (1.0 - overlap * end);
}

float luma(vec3 c) {
	return dot(c, vec3(0.299, 0.587, 0.114));
}

// Blends `top` onto `base` by a paint program's mode, at strength s.
vec3 blend_colors(vec3 base, vec3 top, int mode, float s) {
	vec3 b = pow(max(base, vec3(0.0)), vec3(1.0 / 2.2));
	vec3 t = pow(max(top, vec3(0.0)), vec3(1.0 / 2.2));
	vec3 r = t;
	if (mode == 1) {
		r = b * t;
	} else if (mode == 2) {
		r = mix(2.0 * b * t, 1.0 - 2.0 * (1.0 - b) * (1.0 - t), step(0.5, b));
	} else if (mode == 3) {
		r = (1.0 - 2.0 * t) * b * b + 2.0 * t * b;
	}
	return pow(mix(b, r, clamp(s, 0.0, 1.0)), vec3(2.2));
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
	float shift;
	float primary;
	float secondary;
};

Hair hair_surface(vec2 uv, vec4 vertex_color) {
	Hair h;
	float root = texture(root_map, uv).r;
	root = mix(root, 1.0 - root, invert_root_tip);
	float id = texture(id_map, uv).r;

	vec3 col = vec3(mix(1.0, texture(blend_map, uv).r, blend_map_strength));
	vec3 strand = mix(root_color, tip_color, root);
	col = blend_colors(col, strand, strand_blend_mode,
			strand_strength * mix(root_strength, tip_strength, root));
	float shine = 0.0;
	if (dyes_active) {
		float w1 = dye_weight(id, dye1_range, root, dye1_end_overlap, dye1_end_invert) * dye1_strength;
		float w2 = dye_weight(id, dye2_range, root, dye2_end_overlap, dye2_end_invert) * dye2_strength;
		col = blend_colors(col, dye1_color, dye1_blend_mode, w1);
		col = blend_colors(col, dye2_color, dye2_blend_mode, w2);
		shine = w1 * dye1_specular + w2 * dye2_specular;
	}
	if (hair_color.a > 0.0) {
		float ref = max(luma(mix(root_color, tip_color, 0.5)), 0.002);
		col = mix(col, hair_color.rgb * clamp(luma(col) / ref, 0.0, 3.0), hair_color.a);
	}
	col *= mix(vec3(1.0), mix(vertex_gray_color, vec3(1.0), vertex_color.g), vertex_color_strength);
	h.albedo = clamp(col * diffuse_strength, 0.0, 1.0);

	vec3 orm = texture(orm_map, uv).rgb;
	h.ao = orm.r;
	h.roughness = clamp(mix(0.5, orm.g, roughness_map_strength), 0.15, 1.0);
	float spec_map = mix(1.0, 0.5 + id, spec_map_strength);
	h.specular = specular_strength * specular_scale * spec_map;
	h.primary = specular_strength * spec_map * (1.0 + shine);
	h.secondary = secondary_specular_strength * spec_map;

	vec3 offset = mix(black_offset, white_offset, id);
	vec2 flow = (texture(flow_map, uv).rg + offset.xy) * 2.0 - 1.0;
	if (flip_flow_y) {
		flow.y = -flow.y;
	}
	h.flow = length(flow) > 0.01 ? normalize(flow) : vec2(1.0, 0.0);
	h.shift = offset.z;
	return h;
}

float strand_highlight(vec3 t, vec3 h, float e) {
	float th = dot(t, h);
	return smoothstep(-1.0, 0.0, th) * pow(max(1.0 - th * th, 0.0), 0.5 * e) * (e + 2.0) / (8.0 * PI);
}

void light() {
	vec3 lc = LIGHT_COLOR * ATTENUATION;
	float wrap = clamp(dot(NORMAL, LIGHT) * 0.75 + 0.25, 0.0, 1.0);
	DIFFUSE_LIGHT += lc * wrap / PI;
	// Light from behind, through the hair.
	DIFFUSE_LIGHT += lc * transmission * pow(clamp(dot(VIEW, -LIGHT), 0.0, 1.0), 4.0) / PI;

	vec3 hv = normalize(LIGHT + VIEW);
	float e = 2.0 / max(pow(ROUGHNESS, 4.0), 0.01) - 2.0;
	// Hair keratin reflects about 4.6% head on (IOR 1.55), more at grazing angles.
	float fresnel = 0.046 + 0.954 * pow(1.0 - clamp(dot(hv, VIEW), 0.0, 1.0), 5.0);
	vec3 t1 = normalize(v_strand + NORMAL * (v_shift + primary_shift));
	vec3 t2 = normalize(v_strand + NORMAL * (v_shift + secondary_shift));
	vec3 lobes = vec3(v_primary * strand_highlight(t1, hv, e))
			+ ALBEDO * v_secondary * strand_highlight(t2, hv, e * 0.5);
	SPECULAR_LIGHT += lc * SPECULAR_AMOUNT * highlight_gain * fresnel * wrap * lobes;
}

#define HAIR_SURFACE(uv) Hair h = hair_surface(uv, COLOR); ALBEDO = h.albedo; AO = h.ao; AO_LIGHT_AFFECT = 1.0; ROUGHNESS = h.roughness; SPECULAR = h.specular; ANISOTROPY = anisotropy; ANISOTROPY_FLOW = h.flow; v_strand = normalize(TANGENT * h.flow.x + BINORMAL * h.flow.y); v_shift = h.shift; v_primary = h.primary; v_secondary = h.secondary
