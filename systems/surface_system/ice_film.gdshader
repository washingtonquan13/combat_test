shader_type canvas_item;
render_mode unshaded, blend_disabled;

// Ice for decal_surface.gd: hoarfrost, not a glassy sheet. A matte white
// rime, patchy where it thins, its outline feathery and broken, with a
// fine crystalline grain the light glints off.

#include "res://systems/surface_system/film_common.gdshaderinc"

uniform vec3 frost_color : source_color = vec3(0.9, 0.96, 1.0);
// Where the rime is thin, the cold blue of the ground showing through.
uniform vec3 thin_color : source_color = vec3(0.62, 0.78, 0.92);
uniform float alpha_max : hint_range(0.0, 1.0) = 0.8;
// How far the outline wanders off the cells' edge.
uniform float edge_wander = 0.45;
// Frost patches per meter, and how much of the sheet is bare between them.
uniform float patch_scale = 0.9;
uniform float patchiness : hint_range(0.0, 1.0) = 0.6;
// The grain: crystals per meter.
uniform float grain_scale = 22.0;

float patches(vec2 m) {
	float n = fbm(m * patch_scale + 7.3);
	return mix(1.0, smoothstep(0.25, 0.65, n), patchiness);
}

float grain(vec2 m) {
	return noise(m * grain_scale) * 0.6 + noise(m * grain_scale * 2.1 + 3.7) * 0.4;
}

float film_height(vec2 uv) {
	vec2 m = meters(uv);
	float rime = body(uv, edge_wander) * patches(m);
	// Thicker inside, where it has had longest to build.
	rime *= 0.75 + 0.25 * smoothstep(0.0, 1.5, depth_m(uv));
	rime *= 0.8 + 0.2 * grain(m);
	return receded(rime, uv);
}

vec4 film_albedo(vec2 uv, float h) {
	vec2 m = meters(uv);
	float thick = smoothstep(0.15, 0.85, h);
	vec3 color = mix(thin_color, frost_color, thick);
	// Feathery: the thinnest rime is speckled, not smooth.
	float speckle = smoothstep(0.35, 0.7, grain(m));
	float alpha = smoothstep(0.02, 0.35, h) * mix(speckle, 1.0, thick) * alpha_max;
	return vec4(color, alpha);
}

vec3 film_emission(vec2 uv, float h) {
	return vec3(0.0);
}

#include "res://systems/surface_system/film_passes.gdshaderinc"
