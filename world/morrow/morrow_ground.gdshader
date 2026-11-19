shader_type spatial;

// The Morrow overworld's ground (MorrowTerrain): seven layers painted by two
// maps that cover the whole grid at a metre a texel, written by
// tools/blockout/morrow_terrain.py.
//   ground_nature: R soil, G rock, B dirt; grass is what is left.
//   ground_town:   R asphalt, G paving, B cobble, laid over the nature.
// Seen from the overworld camera, so albedo and normal only; each layer's
// roughness is a constant. Rock is read triplanar so cut slopes don't
// stretch; the rest is read flat, twice, at two scales, so the tiles don't
// show as a grid from a hundred metres up.

uniform sampler2D grass_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D grass_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D soil_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D soil_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dirt_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dirt_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D asphalt_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D asphalt_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D paving_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D paving_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D cobble_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D cobble_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D nature_mask : filter_linear, repeat_disable;
uniform sampler2D town_mask : filter_linear, repeat_disable;
// World x, z of the maps' corner, and one over their size in metres.
uniform vec4 mask_rect = vec4(-1024.0, -1024.0, 0.00048828125, 0.00048828125);
// Seamless grey noise: edges of the paint, and colour drift.
uniform sampler2D variation : filter_linear_mipmap, repeat_enable;

// Tiles a metre: how many times each texture repeats in one metre.
uniform float grass_tile = 0.25;
uniform float soil_tile = 0.25;
uniform float rock_tile = 0.12;
uniform float dirt_tile = 0.3;
uniform float asphalt_tile = 0.2;
uniform float paving_tile = 0.25;
uniform float cobble_tile = 0.3;

varying vec3 world_pos;
varying vec3 tri_weights;

vec3 triplanar(sampler2D tex, vec3 pos) {
	return texture(tex, pos.xy).rgb * tri_weights.z
		+ texture(tex, pos.xz).rgb * tri_weights.y
		+ texture(tex, pos.zy).rgb * tri_weights.x;
}

// The layer at its own scale and at a third of it, so its repeat breaks up.
vec3 two_scale(sampler2D tex, vec2 uv, float b) {
	return mix(texture(tex, uv).rgb, texture(tex, uv * 0.31 + 0.37).rgb, b);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 n = abs(NORMAL);
	tri_weights = pow(n, vec3(6.0));
	tri_weights /= dot(tri_weights, vec3(1.0));
	// The mesh has no tangents: the ground's own, world-aligned.
	TANGENT = normalize(vec3(0.0, 0.0, -1.0) * n.x + vec3(1.0, 0.0, 0.0) * n.y + vec3(1.0, 0.0, 0.0) * n.z);
	BINORMAL = normalize(vec3(0.0, 1.0, 0.0) * n.x + vec3(0.0, 0.0, -1.0) * n.y + vec3(0.0, 1.0, 0.0) * n.z);
}

void fragment() {
	vec2 xz = world_pos.xz;
	float var_slow = texture(variation, xz * 0.004).r;
	float var_mid = texture(variation, xz * 0.03).r;
	float var_fine = texture(variation, xz * 0.21).r;

	vec2 mask_uv = (xz - mask_rect.xy) * mask_rect.zw;
	vec3 nat = texture(nature_mask, mask_uv).rgb;
	vec3 town = texture(town_mask, mask_uv).rgb;
	// Paint edges broken up by the noise, so a 1 m texel's blur reads as
	// ground giving way, not a soft line.
	float edge = (var_fine - 0.5) * 0.6 + (var_mid - 0.5) * 0.4;
	nat = clamp((nat - 0.5) * 2.2 + 0.5 + edge, 0.0, 1.0) * step(0.02, nat);
	town = clamp((town - 0.5) * 4.0 + 0.5 + edge * 0.5, 0.0, 1.0) * step(0.02, town);

	float b = smoothstep(0.35, 0.65, var_mid);
	vec3 g_a = two_scale(grass_albedo, xz * grass_tile, b) * vec3(0.62, 0.78, 0.5);
	vec3 s_a = two_scale(soil_albedo, xz * soil_tile, b) * vec3(0.78, 0.72, 0.64);
	vec3 r_a = triplanar(rock_albedo, world_pos * rock_tile);
	vec3 d_a = two_scale(dirt_albedo, xz * dirt_tile, b) * vec3(0.85, 0.8, 0.72);
	vec3 a_a = texture(asphalt_albedo, xz * asphalt_tile).rgb;
	vec3 p_a = texture(paving_albedo, xz * paving_tile).rgb;
	vec3 c_a = texture(cobble_albedo, xz * cobble_tile).rgb;

	vec3 g_n = mix(texture(grass_normal, xz * grass_tile).rgb, vec3(0.5, 0.5, 1.0), 0.5);
	vec3 s_n = texture(soil_normal, xz * soil_tile).rgb;
	vec3 r_n = triplanar(rock_normal, world_pos * rock_tile);
	vec3 d_n = texture(dirt_normal, xz * dirt_tile).rgb;
	vec3 a_n = texture(asphalt_normal, xz * asphalt_tile).rgb;
	vec3 p_n = texture(paving_normal, xz * paving_tile).rgb;
	vec3 c_n = texture(cobble_normal, xz * cobble_tile).rgb;

	// Nature first, each layer over the last: grass, soil, dirt, rock.
	vec3 col = mix(g_a, s_a, nat.r);
	vec3 nrm = mix(g_n, s_n, nat.r);
	float rough = mix(0.95, 0.9, nat.r);
	col = mix(col, d_a, nat.b);
	nrm = mix(nrm, d_n, nat.b);
	rough = mix(rough, 0.9, nat.b);
	col = mix(col, r_a, nat.g);
	nrm = mix(nrm, r_n, nat.g);
	rough = mix(rough, 0.8, nat.g);

	// Colour drift across hundreds of metres: warmer and cooler, lighter
	// and darker. The town's surfaces drift less.
	vec3 drift = mix(vec3(0.93, 0.98, 1.04), vec3(1.07, 1.0, 0.9), smoothstep(0.3, 0.7, var_slow));
	drift *= mix(0.88, 1.1, smoothstep(0.25, 0.75, var_mid));
	col *= drift;

	// Then the town over it.
	vec3 street = mix(mix(a_a, p_a, town.g), c_a, town.b);
	vec3 street_n = mix(mix(a_n, p_n, town.g), c_n, town.b);
	float street_r = mix(mix(0.92, 0.85, town.g), 0.8, town.b);
	float paved = clamp(town.r + town.g + town.b, 0.0, 1.0);
	street *= mix(vec3(1.0), drift, 0.4);
	col = mix(col, street, paved);
	nrm = mix(nrm, street_n, paved);
	rough = mix(rough, street_r, paved);

	ALBEDO = col;
	ROUGHNESS = rough;
	METALLIC = 0.0;
	NORMAL_MAP = nrm;
	NORMAL_MAP_DEPTH = 1.0;
}
