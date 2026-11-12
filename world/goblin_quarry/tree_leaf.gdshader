shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap;

// Foliage cards of generated trees. Normals come from the crown's shape, not
// the card (plant_gen.gd), and stay that way on the back face, so a crown
// lights as one volume. COLOR.r is baked occlusion, COLOR.g a per-branch
// random number for tint. The atlas has coverage-preserving mips.
//
// Light through the leaves: the sun behind a crown shows through its far side
// and glows round the edges. Real leaves pass it on through several layers,
// so the crown's own shadow only dims it by half; looking toward the sun adds
// a forward-scatter glow. Thin leaves pass yellow-green and hold back blue.

#include "res://world/goblin_quarry/tree_wind.gdshaderinc"

uniform sampler2D atlas : source_color, filter_linear_mipmap_anisotropic;
uniform vec3 tint_a = vec3(0.82, 0.9, 0.78);
uniform vec3 tint_b = vec3(1.0, 0.98, 0.82);
uniform float translucency = 0.6;
uniform vec3 transmit = vec3(1.1, 1.3, 0.5);
uniform float wrap = 0.5;
// Scanned leaves bring their own surface (vine_atlas.py): R, G the normal's
// x and y in the atlas, y up the image; B roughness. Off at zero. The cards
// carry no tangents, so the atlas's axes are found from how position and UV
// change across the pixel.
uniform sampler2D surface : hint_default_white, filter_linear_mipmap_anisotropic;
uniform float surface_relief = 0.0;

void vertex() {
	VERTEX = tree_wind(VERTEX, UV2, COLOR.a, MODEL_MATRIX[3].xyz, TIME);
}

void fragment() {
	vec4 t = texture(atlas, UV);
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	vec3 c = t.rgb * mix(tint_a, tint_b, COLOR.g) * COLOR.r;
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
