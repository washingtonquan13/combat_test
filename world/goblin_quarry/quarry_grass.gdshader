shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, specular_disabled;

// Grass: a 1 m patch of meadow (_fan_patch() in bake_goblin_quarry.gd):
// tufts of twisted spray ribbons, each showing one spray of the atlas, plus
// flat weed stars, clover and seed stalks from the atlas's weed row, so the
// thin blades are texture that mips down smoothly rather than geometry
// thinner than a pixel. The atlas carries only
// each blade's shading; its colour is the ground's own grass layer under the
// clump, graded as the ground shader grades it, so grass grows out of the
// ground instead of sitting on it as a separate carpet. The upper blades
// turn a fresher green, deeper in lush patches and warmer in sunny ones, and
// straw in dry patches. Roots and blades both take the valley's colour drift,
// the same one the ground takes; the greens and the drift live in
// grass_colour.gdshaderinc, which the ground reads too, so past the fade the
// ground can carry the blades' colour. INSTANCE color is per-clump variation.
//
// Patch cards have normals straight up, so they light like the ground under
// them, as BG3's grass does. The meadow's upright clumps keep a dome of
// normals (up at the root, tipping outward toward the top); normal_dome
// blends those toward up: at 0 every card lights exactly like the ground, at
// 1 each clump shades as a mound, which from the game's high camera is
// speckle.
// Roots take the ground's own colour and only the upper blade carries the
// atlas shading, so a card's base never draws a line.
// UV is the point in the card; UV2.x is 0 at the root and 1 at the top,
// UV2.y a random number per card. CUSTOM0.xyz is the card's root in the
// mesh's space; meshes without CUSTOM0 (the meadow's) read zero, so their
// cards root at the instance origin. On grass patches CUSTOM0.w is a random
// number per star, CUSTOM1.xyz the move from a card's short shape to its
// long one (see INSTANCE_CUSTOM below) and CUSTOM1.w the card's facing. Colour, wind and distance are all taken at the card's root. With
// distance a share of the cards fold away, and past fade_start each card
// sinks into the ground about its root. INSTANCE_CUSTOM.a is the local
// density (0-1, thinning toward a field's edge): it folds cards the same way.
//
// Wind is the shared one (wind.gdshaderinc), in world space: every clump
// leans the same way downwind and sways about that lean, and gust fronts
// roll across the field. A card bends about its own root and keeps its
// length, so tips swing down as they swing out instead of stretching.
// `suppleness` scales it per material; dry patches and dry stalks are
// stiffer.
//
// INSTANCE_CUSTOM picks the atlas cells: g how many rows, b a fixed column,
// or 4 for any. r is the first row on the meadow; on grass patches it is the
// tall share, 0-1: the share of the patch's stars grown long, which show the
// long rows 0-1 instead of the short rows 2-3. atlas_grid is
// the atlas's columns and rows: 8 x 5 sprays and weeds, 4 x 4 meadow plants. The same shader draws the meadow plants
// (clover, weeds, flowers, stalks) with `painted` on: their atlas is in full
// colour and keeps it, tinted only by INSTANCE color.

#include "res://world/goblin_quarry/wind.gdshaderinc"
#include "res://world/goblin_quarry/grass_colour.gdshaderinc"

uniform sampler2D tufts : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D ground_grass : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D ground_soil : source_color, filter_linear_mipmap, repeat_enable;
uniform bool painted = false;
uniform vec2 atlas_grid = vec2(4.0, 4.0);
// The valley's relief and shape maps, as the ground reads them
// (quarry_ground.gdshader, tools/quarry/terrain_relief.py). A clump takes the
// light of the ground's swell under it, is shaded where the valley closes
// off the sky, and grows deeper green in a field's dips and paler on its
// rises. All three amounts at 0 leave the grass as it was.
uniform sampler2D terrain_relief : filter_linear_mipmap, repeat_disable;
uniform sampler2D terrain_masks : filter_linear_mipmap, repeat_disable;
uniform vec4 relief_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform float relief_amount = 0.0;
uniform float occlusion_amount = 0.0;
uniform float shape_paint = 0.0;
uniform float grass_tile = 0.33;
// 0: normals straight up (BG3). 1: the mesh's dome.
uniform float normal_dome : hint_range(0.0, 1.0) = 0.25;
// Inside a clump, close to the camera, the lower blades stand in each
// other's shade. Kept to near the camera: from the game's height deep root
// shade reads as dark spots on the ground.
uniform float near_end = 14.0;
// How much a plant gives to the wind: 1 green grass, 0.5 dry, 0.2 dead
// stalks (BG3's Soupleness).
uniform float suppleness = 1.0;
uniform float thin_start = 14.0;
// How much wider surviving grass cards are at fade_start (0.25: x1.25).
uniform float widen = 0.25;
uniform float fade_start = 30.0;
uniform float fade_end = 44.0;
varying float tip;
varying vec3 base;
varying vec3 top;
varying vec2 cell;
varying float near;
varying vec2 swell;
varying float sky;
varying flat float weed;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void vertex() {
	tip = UV2.x;
	vec3 root = CUSTOM0.xyz;
	vec3 origin = (MODEL_MATRIX * vec4(root, 1.0)).xyz;

	// Grass patches: a star grows long when its random number (CUSTOM0.w) is
	// below the instance's tall share (INSTANCE_CUSTOM.r). Its cards move to
	// their long shape (CUSTOM1.xyz) and show the long rows of the atlas,
	// 0-1, instead of the short ones, 2-3.
	// Weed pieces (vertex alpha below 0.5) show the weed row, 4, at the
	// column alpha x 16; those that don't grow have no long shape.
	weed = (!painted && COLOR.a < 0.5) ? 1.0 : 0.0;
	bool grown = !painted && CUSTOM0.w < INSTANCE_CUSTOM.r;
	if (grown) {
		VERTEX += CUSTOM1.xyz;
	}
	float first = painted ? INSTANCE_CUSTOM.r : (grown ? 0.0 : 2.0);

	// Each card shows its own cell of its rows of the atlas: an offset per
	// instance plus one per card (UV2.y is spread evenly over a mesh's cards).
	float cols = atlas_grid.x;
	float cells = INSTANCE_CUSTOM.g * cols;
	float c = mod(floor(hash(MODEL_MATRIX[3].xz) * cells) + floor(UV2.y * cells), cells);
	float col = INSTANCE_CUSTOM.b < 3.5 ? INSTANCE_CUSTOM.b : mod(c, cols);
	cell = vec2(col, first + floor(c / cols));
	if (weed > 0.5) {
		cell = vec2(round(COLOR.a * 16.0), 4.0);
	}

	// One texel up the mips: a card is wider than a texel of the maps.
	vec2 relief_uv = (origin.xz - relief_rect.xy) * relief_rect.zw;
	vec3 relief = textureLod(terrain_relief, relief_uv, 1.0).rgb;
	float dip = (textureLod(terrain_masks, relief_uv, 1.0).b - 0.5) * 2.0 * shape_paint;
	swell = (relief.rg - 0.5) * 2.0 * relief_amount;
	sky = mix(1.0, relief.b, occlusion_amount);

	// Roots: the ground shader's grass layer at the mip it mostly shows,
	// with the ground's drift, so a card's base is the ground under it.
	vec3 drift = ground_drift(origin.xz);
	// The ground there is the grass floor (grass_floor()); a card stands on
	// grass painted dense enough to grow it, taken as cover 0.8.
	float dry;
	vec3 floor_top = grass_top(ground_soil, origin.xz, vec3(1.0), dip, 5.0, dry);
	base = grass_floor(grass_root(textureLod(ground_grass, origin.xz * grass_tile, 7.0).rgb), floor_top, 0.8, 1.0) * drift * COLOR.rgb;
	base *= 1.0 - 0.1 * dip;
	top = grass_top(ground_soil, origin.xz, COLOR.rgb, dip, 0.0, dry) * drift;
	if (weed > 0.5) {
		base = drift * COLOR.rgb;
	}

	float dist = length((VIEW_MATRIX * vec4(origin, 1.0)).xyz);
	near = 1.0 - smoothstep(near_end * 0.4, near_end, dist);
	float thin = smoothstep(thin_start, fade_start, dist);
	float keep = mix(1.0, 0.6, thin) * INSTANCE_CUSTOM.a;
	// Grass patch cards that survive the thinning widen, up to x1.25 at
	// fade_start, so the field keeps its cover as it thins (5.6 of the grass
	// proposal). A card widens along its own side, from its facing.
	if (!painted) {
		vec3 side = vec3(-sin(CUSTOM1.w), 0.0, cos(CUSTOM1.w));
		VERTEX += side * dot(VERTEX - root, side) * (widen * thin);
	}
	float alive = clamp((keep - UV2.y) / 0.08, 0.0, 1.0);
	float sink = 1.0 - smoothstep(fade_start, fade_end, dist);
	float shown = alive * sink;

	// Wind, in the mesh's own space: the world direction turned into it.
	// The offset grows with height x tip², so as tip³ up the card; then the
	// vertex is put back at its rest distance from the card's root. Cards
	// folded away skip it.
	if (shown > 0.0) {
		float give = suppleness * mix(1.0, 0.5, dry) * (painted && INSTANCE_CUSTOM.r > 2.5 ? 0.2 : 1.0);
		float lean = wind_lean(origin.xz, TIME, 1.0) * give;
		vec3 rest = VERTEX - root;
		vec3 bent = rest + wind_dir_local(MODEL_MATRIX) * lean * max(rest.y, 0.0) * tip * tip;
		VERTEX = root + bent * (length(rest) / max(length(bent), 1e-4));
	}
	VERTEX = root + (VERTEX - root) * shown;
}

void fragment() {
	// Inset so a cell's mips don't pick up its neighbour's blades.
	vec2 uv = (cell + clamp(UV, vec2(0.01), vec2(0.99))) / atlas_grid;
	vec4 t = texture(tufts, uv);
	// Godot turns the normal over on a card's back face; both faces should
	// light like the ground, so turn it back.
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
	// Flatten the dome toward up, then lean it as the ground's swell leans,
	// the way the ground shader does.
	vec3 wn = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	wn = mix(vec3(0.0, 1.0, 0.0), wn, normal_dome);
	wn = wn / max(wn.y, 0.2) - vec3(swell.x, 0.0, swell.y);
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
	// The atlas shading is kept shallow: deep shade at the roots reads as dark
	// spots on the ground from the game's high camera.
	if (painted) {
		ALBEDO = t.rgb * COLOR.rgb * mix(0.8, 1.0, tip);
	} else if (weed > 0.5) {
		ALBEDO = t.rgb * base * mix(0.7, 1.0, smoothstep(0.0, 0.6, tip));
	} else {
		ALBEDO = mix(base, top, smoothstep(0.0, 0.7, tip)) * mix(vec3(1.0), mix(0.45 + 0.6 * t.rgb, 0.2 + 0.95 * t.rgb, near), smoothstep(0.0, 0.5, tip));
		ALBEDO *= mix(1.0, mix(0.6, 1.0, smoothstep(0.0, 0.65, tip)), near);
	}
	ALBEDO *= mix(0.9, 1.0, sky);
	ALPHA = t.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 0.85;
	AO = mix(0.9, 1.0, tip) * sky;
	AO_LIGHT_AFFECT = 0.3;
	// Light through a blade comes out a deeper, yellower green.
	BACKLIGHT = (painted ? ALBEDO : top * vec3(1.0, 0.95, 0.5)) * 0.25 * tip;
}
