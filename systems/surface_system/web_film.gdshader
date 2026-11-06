shader_type canvas_item;
render_mode unshaded, blend_disabled;

// Webbing for decal_surface.gd: a tiling sheet of overlapping orb webs
// over gauzy netting (web_tile, drawn by tools/vfx/make_web_texture.py),
// laid in world meters so neighbouring patches line up. Cut to the
// patch's cells with a ragged edge; as it recedes the faint gauze goes
// first and the stout strands last. Silk lies flat, so it barely shows in
// the normal map.

#include "res://systems/surface_system/film_common.gdshaderinc"

uniform sampler2D web_tile : source_color, filter_linear_mipmap, repeat_enable;
// Meters one repeat of web_tile covers.
uniform float tile_m = 3.0;
uniform float alpha_max : hint_range(0.0, 1.0) = 0.95;

vec4 silk(vec2 uv) {
	return texture(web_tile, meters(uv) / tile_m);
}

float film_height(vec2 uv) {
	return receded(silk(uv).a * body(uv, 0.6), uv);
}

vec4 film_albedo(vec2 uv, float h) {
	return vec4(silk(uv).rgb, clamp(h * 1.5, 0.0, 1.0) * alpha_max);
}

vec3 film_emission(vec2 uv, float h) {
	return vec3(0.0);
}

#include "res://systems/surface_system/film_passes.gdshaderinc"
