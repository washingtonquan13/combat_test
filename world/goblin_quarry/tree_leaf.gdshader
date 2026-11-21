shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap;

// Foliage cards of generated trees. Normals mix the crown's shape and the
// card's face (plant_gen.gd: mostly the crown on firs and ferns, mostly the
// card on broadleaves and bushes, whose `surface` map shapes each card), and
// stay that way on the back face. COLOR.r is baked occlusion, COLOR.g a per-branch
// random number for tint. The atlas has coverage-preserving mips.
//
// The atlases are a pale sage (leaf_atlas.py and the others grade them); the
// colour is put on here. tint_a and tint_b vary it per branch (COLOR.g).
// young and old vary it per plant: each instance draws an age from where it
// stands, so a stand of one tree mesh shows fresh yellow-green crowns beside
// dark, cooler ones. Plants drawn as one mesh (the vines) share one age.
//
// Light through the leaves: the sun behind a crown shows through its far side
// and glows round the edges. Real leaves pass it on through several layers,
// so the crown's own shadow only dims it by half; looking toward the sun adds
// a forward-scatter glow. Thin leaves pass yellow-green and hold back blue.

#include "res://world/goblin_quarry/tree_wind.gdshaderinc"

uniform sampler2D atlas : source_color, filter_linear_mipmap_anisotropic;
uniform vec3 tint_a = vec3(0.78, 0.92, 0.72);
uniform vec3 tint_b = vec3(1.02, 0.98, 0.76);
uniform vec3 young = vec3(1.08, 1.08, 0.8);
uniform vec3 old = vec3(0.8, 0.88, 0.86);
// Fallen leaves round a trunk (COLOR.b, plant_gen.gd's _skirt()): this much
// of the colour goes to a dry brown of the same brightness.
uniform vec3 litter = vec3(1.25, 0.95, 0.6);
uniform float translucency = 0.6;
uniform vec3 transmit = vec3(1.1, 1.3, 0.5);
uniform float wrap = 0.5;
// Scanned leaves bring their own surface (vine_atlas.py, leaf_atlas.py): R,
// G the normal's x and y in the atlas, y up the image; B roughness. Off at
// zero. The cards
// carry no tangents, so the atlas's axes are found from how position and UV
// change across the pixel.
uniform sampler2D surface : hint_default_white, filter_linear_mipmap_anisotropic;
uniform float surface_relief = 0.0;

varying float age;

void vertex() {
	vec3 o = MODEL_MATRIX[3].xyz;
	age = fract(sin(dot(o.xz, vec2(12.9898, 78.233))) * 43758.5453);
	VERTEX = tree_wind(VERTEX, UV2, COLOR.a, MODEL_MATRIX, TIME);
}

void fragment() {
	vec4 t = texture(atlas, UV);
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	vec3 c = t.rgb * mix(tint_a, tint_b, COLOR.g) * mix(old, young, age) * COLOR.r;
	c = mix(c, vec3(dot(c, vec3(0.333))) * litter, COLOR.b);
	ALBEDO = c;
	ALPHA = t.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 0.75;
	SPECULAR = 0.25;
	if (surface_relief > 0.0) {
		vec3 s = texture(surface, UV).rgb;
		vec3 px = dFdx(VERTEX);
		vec3 py = dFdy(VERTEX);
		vec2 ux = dFdx(UV);
		vec2 uy = dFdy(UV);
		vec3 along_u = px * uy.y - py * ux.y;
		vec3 along_v = py * ux.x - px * uy.x;
		float det = ux.x * uy.y - uy.x * ux.y;
		if (abs(det) > 1e-12) {
			along_u = normalize(along_u * sign(det));
			along_v = normalize(along_v * sign(det));
			vec2 d = (s.rg * 2.0 - 1.0) * surface_relief;
			// V runs down the image, the stored y up it.
			NORMAL = normalize(NORMAL + along_u * d.x - along_v * d.y);
		}
		ROUGHNESS = s.b;
	}
}

void light() {
	float ndl = dot(NORMAL, LIGHT);
	float front = max(0.0, (ndl + wrap) / ((1.0 + wrap) * (1.0 + wrap)));
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * front / PI;

	float back = max(0.0, -ndl) * 0.5;
	float scatter = pow(clamp(dot(-VIEW, LIGHT), 0.0, 1.0), 6.0);
	float lit = LIGHT_IS_DIRECTIONAL ? mix(ATTENUATION, 1.0, 0.5) : ATTENUATION;
	DIFFUSE_LIGHT += LIGHT_COLOR * lit * (back + scatter) * transmit * translucency / PI;
}
