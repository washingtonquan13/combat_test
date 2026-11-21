shader_type spatial;

// Four ground layers painted by vertex colour: R rock, G soil, B grass, A dirt.
// UV carries the water: x the riverbed's stones, y how damp the bank is.
//
// Each layer's ARM texture carries its height in B (metallic is unused;
// tools/quarry/height_from_normal.py writes it). Layers meet by height: where
// two are painted half and half, the higher texel wins, so soil settles into
// the gaps between the dirt's stones and the stones keep their edges.
//
// The flat layers are read at two random offsets chosen by a slow noise and
// blended where the noise moves from one to the next, so the 3 m tiles stop
// lining up into a grid when seen from the rim.
//
// Two maps cover the whole valley at 0.2 m a texel, from
// tools/quarry/terrain_relief.py. They describe a finer ground than the
// mesh has: bumps and the rills rain would cut down the slopes. The mesh
// stays as it is; the maps bend the light and move the paint.
//
// A pixel reads only the layers that can show there. Paint decides that
// before any texture is read: a layer whose paint, plus the most its height
// could lift it, stays below the blend would get weight zero. Most of the
// ground is one or two layers; reading all four (rock triplanar, soil and
// dirt untiled) cost about thirty texture reads a pixel. Reads inside those
// branches take their derivatives from outside them (textureGrad), so mips
// stay smooth where a branch starts.
//
// Under the grass cards the grass layer is the shade at the blades' roots.
// The cards sink away between grass_far_start and grass_far_end, so over the
// same distance the layer turns to the colour a field of blades shows from
// afar: the blades' own green (grass_colour.gdshaderinc, which the cards
// read too) over field_cover of the ground, darkened by field_shade for the
// shade inside the field. Zooming out then doesn't darken the field
// (docs/plans/bg3_grass_proposal.md, 5.6). The colour drift is the same
// computed noise the cards read, so their roots match the ground under them.

#include "res://world/goblin_quarry/grass_colour.gdshaderinc"

uniform sampler2D rock_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_arm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D soil_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D soil_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D soil_arm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D grass_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D grass_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D grass_arm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dirt_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dirt_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dirt_arm : filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D bed_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D bed_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D bed_arm : filter_linear_mipmap_anisotropic, repeat_enable;

// Seamless grey noise. Drives the tile offsets.
uniform sampler2D variation : filter_linear_mipmap, repeat_enable;

// R,G: slope of the fine ground along +X and +Z (0.5 level, ends = slope 1).
// B: how much sky the spot sees past the valley's walls and banks.
uniform sampler2D terrain_relief : filter_linear_mipmap, repeat_disable;
// R: runoff, where rain gathers on a slope. G: hollow above 0.5, crest below.
uniform sampler2D terrain_masks : filter_linear_mipmap, repeat_disable;
// World x, z of the maps' corner, and one over their size in metres.
uniform vec4 relief_rect = vec4(0.0, 0.0, 1.0, 1.0);
// All three are 0 until the bake sets the maps.
uniform float relief_amount = 0.0;
uniform float occlusion_amount = 0.0;
uniform float shape_paint = 0.0;

uniform float rock_tile = 0.22;
uniform float bed_tile = 0.45;
uniform float soil_tile = 0.30;
uniform float grass_tile = 0.33;
uniform float dirt_tile = 0.36;
// How far a layer's relief reaches into its neighbour, in height units.
uniform float blend_depth = 0.18;
// The grass cards' fade (quarry_grass.gdshader's fade_start, fade_end): over
// it the grass layer takes over the field's colour.
uniform float grass_far_start = 28.0;
uniform float grass_far_end = 44.0;
// From afar, the share of the ground the blades hide, and how much the
// field's own shade darkens them. Set from captures at 25 m and 60 m (change 4).
uniform float field_cover = 0.48;
uniform float field_shade = 0.5;

varying vec3 world_pos;
varying vec3 tri_weights;
varying vec2 wet;

// Rock is read on three planes; a plane whose weight is negligible is
// skipped. dx, dy: the derivatives of pos, taken outside any branch.
vec4 triplanar(sampler2D tex, vec3 pos, vec3 dx, vec3 dy) {
	vec4 s = vec4(0.0);
	if (tri_weights.z > 0.002) {
		s += textureGrad(tex, pos.xy, dx.xy, dy.xy) * tri_weights.z;
	}
	if (tri_weights.y > 0.002) {
		s += textureGrad(tex, pos.xz, dx.xz, dy.xz) * tri_weights.y;
	}
	if (tri_weights.x > 0.002) {
		vec2 f = vec2(-1.0, 1.0);
		s += textureGrad(tex, pos.zy * f, dx.zy * f, dy.zy * f) * tri_weights.x;
	}
	return s;
}

vec2 hash2(float n) {
	return fract(sin(vec2(n * 127.1 + 1.7, n * 311.7 + 9.3)) * 43758.5453);
}

// One read of a flat layer, untiled: at two offsets, blended by b. dx, dy
// are uv's derivatives from outside any branch, so a pixel that reads only
// one offset gets the same mip as its neighbours that read both: no sparkle
// where the blend starts.
vec4 untiled(sampler2D tex, vec2 uv, vec2 dx, vec2 dy, vec2 o1, vec2 o2, float b) {
	if (b < 0.01) {
		return textureGrad(tex, uv + o1, dx, dy);
	}
	if (b > 0.99) {
		return textureGrad(tex, uv + o2, dx, dy);
	}
	return mix(textureGrad(tex, uv + o1, dx, dy), textureGrad(tex, uv + o2, dx, dy), b);
}

void vertex() {
	world_pos = VERTEX * vec3(1.0, -1.0, 1.0);
	wet = UV;
	vec3 n = abs(NORMAL);
	tri_weights = pow(n, vec3(6.0));
	tri_weights /= dot(tri_weights, vec3(1.0));
	TANGENT = normalize(vec3(0.0, 0.0, -1.0) * n.x + vec3(1.0, 0.0, 0.0) * n.y + vec3(1.0, 0.0, 0.0) * n.z);
	BINORMAL = normalize(vec3(0.0, 1.0, 0.0) * n.x + vec3(0.0, 0.0, -1.0) * n.y + vec3(0.0, 1.0, 0.0) * n.z);
}

float lum(vec3 c) {
	return grass_colour_lum(c);
}

// Unpacks a normal map texel, adds `detail` to it (whiteout blend), packs it back.
vec3 add_normal(vec3 base, vec3 detail, float amount) {
	vec3 a = base * 2.0 - 1.0;
	vec3 b = detail * 2.0 - 1.0;
	vec3 n = normalize(vec3(a.xy + b.xy * amount, a.z));
	return n * 0.5 + 0.5;
}

void fragment() {
	vec2 xz = world_pos.xz;
	vec4 var_fast = texture(variation, xz * 0.05);

	// Tile offsets: eight random placements, the slow noise walking between them.
	float k = var_fast.r * 8.0;
	float i = floor(k);
	vec2 o1 = hash2(i);
	vec2 o2 = hash2(i + 1.0);
	float ob = smoothstep(0.3, 0.7, fract(k));

	vec2 uv_s = xz * soil_tile;
	vec2 uv_g = xz * grass_tile;
	vec2 uv_d = xz * dirt_tile;
	vec3 rock_pos = world_pos * rock_tile;
	// Every derivative the branches below need, taken before any of them.
	vec2 xz_dx = dFdx(xz);
	vec2 xz_dy = dFdy(xz);
	vec3 rock_dx = dFdx(rock_pos);
	vec3 rock_dy = dFdy(rock_pos);

	// Shape moves the paint: rain washes crests and rills down to dirt and
	// stones, and what it carries settles in the hollows as soil. Grass
	// keeps its ground, the cards stand on it.
	vec2 relief_uv = (xz - relief_rect.xy) * relief_rect.zw;
	vec3 relief = texture(terrain_relief, relief_uv).rgb;
	vec3 shape = texture(terrain_masks, relief_uv).rgb;
	float hollow = (shape.g - 0.5) * 2.0;
	float wash = clamp(max(-hollow, 0.0) * 0.5 + shape.r, 0.0, 1.0) * shape_paint;
	float fill = max(hollow, 0.0) * shape_paint;
	vec4 paint = COLOR;
	paint.a += wash * 0.45 * (1.0 - paint.b);
	paint.g += fill * 0.45 * (1.0 - paint.b);

	// Which layers can show. A layer's height lifts it by at most h_max
	// (see h below); every lift is at least its paint, so the blend's top is
	// at least the highest paint less blend_depth. A layer that can't reach
	// that gets weight zero, so it isn't read at all.
	const vec4 h_max = vec4(0.5, 0.5, 0.35, 0.5);
	float least_top = max(max(paint.r, paint.g), max(paint.b, paint.a)) - blend_depth;
	bvec4 can = greaterThan(paint + h_max, vec4(least_top));
	vec2 s_dx = xz_dx * soil_tile, s_dy = xz_dy * soil_tile;
	vec2 g_dx = xz_dx * grass_tile, g_dy = xz_dy * grass_tile;
	vec2 d_dx = xz_dx * dirt_tile, d_dy = xz_dy * dirt_tile;

	vec3 r_m = vec3(0.0), s_m = vec3(0.0), g_m = vec3(0.0), d_m = vec3(0.0);
	if (can.r) {
		r_m = triplanar(rock_arm, rock_pos, rock_dx, rock_dy).rgb;
	}
	if (can.g) {
		s_m = untiled(soil_arm, uv_s, s_dx, s_dy, o1, o2, ob).rgb;
	}
	if (can.b) {
		g_m = textureGrad(grass_arm, uv_g, g_dx, g_dy).rgb;
	}
	if (can.a) {
		d_m = untiled(dirt_arm, uv_d, d_dx, d_dy, o1, o2, ob).rgb;
	}

	// Height blend. Paint decides how high a layer is lifted, its texture
	// decides where inside the blend it shows. The grass layer is flattened:
	// its cards stand on it, its own relief would only show as gravel.
	vec4 h = vec4(r_m.b, s_m.b, g_m.b * 0.4 + 0.3, d_m.b) * 0.5;
	vec4 lift = paint + h;
	float top = max(max(lift.r, lift.g), max(lift.b, lift.a)) - blend_depth;
	vec4 w = max(lift - vec4(top), vec4(0.0));
	w /= max(w.r + w.g + w.b + w.a, 0.0001);
	float height = dot(h, w) * 2.0;

	// Colour and normal, read only where the layer has weight.
	// Forest floor, not dry field: the grass layer pulled green and dark,
	// the soil to a damp loam. Under the grass cards the ground is the shade
	// at the roots of the blades, so the texture's gravel is evened out
	// toward its average and darkened: gaps between clumps read as deeper
	// grass, not bare stones.
	vec3 r_a = vec3(0.0), s_a = vec3(0.0), g_a = vec3(0.0), d_a = vec3(0.0);
	vec3 r_n = vec3(0.0), s_n = vec3(0.0), g_n = vec3(0.0), d_n = vec3(0.0);
	if (w.r > 0.0) {
		r_a = triplanar(rock_albedo, rock_pos, rock_dx, rock_dy).rgb;
		r_n = triplanar(rock_normal, rock_pos, rock_dx, rock_dy).rgb;
		r_a = mix(vec3(lum(r_a)), r_a, 0.75);
	}
	if (w.g > 0.0) {
		s_a = untiled(soil_albedo, uv_s, s_dx, s_dy, o1, o2, ob).rgb * vec3(0.72, 0.68, 0.6);
		s_n = untiled(soil_normal, uv_s, s_dx, s_dy, o1, o2, ob).rgb;
	}
	if (w.b > 0.0) {
		g_a = textureGrad(grass_albedo, uv_g, g_dx, g_dy).rgb;
		g_a = mix(textureLod(grass_albedo, uv_g, 7.0).rgb, g_a, 0.3);
		g_a = grass_root(g_a);
		g_n = mix(textureGrad(grass_normal, uv_g, g_dx, g_dy).rgb, vec3(0.5, 0.5, 1.0), 0.6);
		// Where the cards have sunk away, the field's colour. Cards grow
		// where the paint has grass (0.08 and up, denser and taller with
		// more) and the mesh is flat enough (up 0.84, the bake's rule).
		float g = COLOR.b;
		float up = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz).y;
		float cover = step(0.08, g) * min(1.0, g * 2.0) * pow(mix(0.55, 1.0, g), 2.0) * smoothstep(0.8, 0.86, up);
		float field = smoothstep(grass_far_start, grass_far_end, length(VERTEX)) * cover * field_cover;
		if (field > 0.0) {
			float dry_field;
			float dip = (shape.b - 0.5) * 2.0 * shape_paint;
			vec3 blades = grass_top(soil_albedo, xz, vec3(1.0), dip, 5.0, dry_field) * field_shade;
			g_a = mix(g_a, blades, field);
		}
	}
	if (w.a > 0.0) {
		d_a = untiled(dirt_albedo, uv_d, d_dx, d_dy, o1, o2, ob).rgb;
		d_a = mix(vec3(lum(d_a)), d_a, 0.3) * vec3(0.74, 0.72, 0.66);
		d_n = untiled(dirt_normal, uv_d, d_dx, d_dy, o1, o2, ob).rgb;
	}

	// Colour drift across the valley: warm and cool patches at a few metres,
	// light and dark at less. Rock keeps most of its own colour.
	vec3 drift = ground_drift(xz);
	vec3 dry = r_a * w.r + s_a * w.g + g_a * w.b + d_a * w.a;
	dry *= mix(drift, vec3(1.0), w.r * 0.75);

	// The riverbed's stones stand out of the bank first, the gaps last.
	// With wet.x under 0.143 the bed can't show (its height is at most 1),
	// so away from the water it isn't read.
	vec3 b_a = vec3(0.0), b_m = vec3(0.0), b_n = vec3(0.0);
	float bed = 0.0;
	if (wet.x > 0.142) {
		vec2 uv_b = xz * bed_tile;
		vec2 b_dx = xz_dx * bed_tile, b_dy = xz_dy * bed_tile;
		b_a = textureGrad(bed_albedo, uv_b, b_dx, b_dy).rgb;
		b_m = textureGrad(bed_arm, uv_b, b_dx, b_dy).rgb;
		b_n = textureGrad(bed_normal, uv_b, b_dx, b_dy).rgb;
		bed = clamp(wet.x * (0.3 + b_m.b * 1.8) - 0.2, 0.0, 1.0);
		bed = smoothstep(0.1, 0.7, bed);
	}
	height = mix(height, b_m.b, bed);
	// Damp ground darkens most in its hollows, where water would sit.
	float damp = wet.y * mix(1.15, 0.7, height);
	ALBEDO = mix(dry, b_a * 0.8, bed) * mix(1.0, 0.62, clamp(damp, 0.0, 1.0));
	// Hollows hold damp and litter, crests dry pale; runoff stains rock.
	ALBEDO *= mix(1.0, 0.8, fill) * mix(1.0, 1.08, max(-hollow, 0.0) * shape_paint);
	ALBEDO *= mix(1.0, 0.8, shape.r * w.r * shape_paint);
	float sky = mix(1.0, relief.b, occlusion_amount);
	ALBEDO *= mix(0.9, 1.0, sky);

	vec3 arm = r_m * w.r + s_m * w.g + g_m * w.b + d_m * w.a;
	vec3 nrm = r_n * w.r + s_n * w.g + g_n * w.b + d_n * w.a;
	arm = mix(arm, b_m, bed);
	nrm = mix(nrm, b_n, bed);

	// Far away the normal map's mips have flattened its relief; a read of
	// the dirt at a fifth of its scale puts bumps back at the size a pixel
	// still sees.
	float dist = length(VERTEX);
	float far = smoothstep(14.0, 50.0, dist) * (1.0 - w.r) * (1.0 - bed);
	if (far > 0.0) {
		float t = dirt_tile * 0.21;
		vec3 far_n = textureGrad(dirt_normal, xz * t + o1, xz_dx * t, xz_dy * t).rgb;
		nrm = add_normal(nrm, far_n, far * 0.8);
	}

	// Crevices: the rock's own height deepens its AO.
	AO = arm.r * mix(1.0, mix(0.55, 1.0, r_m.b), w.r) * sky;
	AO_LIGHT_AFFECT = 0.4;
	ROUGHNESS = mix(clamp(arm.g, 0.55, 1.0), 0.35, clamp(damp, 0.0, 1.0) * 0.8);
	METALLIC = 0.0;
	// The fine ground's slope, added to the mesh's own as heights add.
	vec2 fine = (relief.rg - 0.5) * 2.0 * relief_amount;
	vec3 wn = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
	wn = wn / max(wn.y, 0.2) - vec3(fine.x, 0.0, fine.y);
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
	NORMAL_MAP = nrm;
	NORMAL_MAP_DEPTH = 1.1;
}
