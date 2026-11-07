shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled, shadows_disabled;

// The wall's main mass: a strip of the baked wall-of-fire sheet
// (bake_fire_wall.py), tiling sideways along the ribbon so the wall is one
// continuous fire rather than separate tongues. UV.x runs in tiles along
// the wall, UV.y down from the top.

uniform sampler2D flipbook : hint_default_black, filter_linear, repeat_disable;
uniform int columns = 8;
uniform int frames = 64;
uniform float fps = 24.0;
// Frames and tiles this strip is shifted by, so stacked strips differ.
uniform float time_offset = 0.0;
uniform float tile_offset = 0.0;
uniform vec3 core_color : source_color = vec3(1.0, 0.85, 0.55);
uniform vec3 body_color : source_color = vec3(1.0, 0.42, 0.08);
uniform vec3 tip_color : source_color = vec3(0.6, 0.07, 0.02);
uniform float intensity = 1.6;
uniform float opacity = 0.5;
// The ribbon's length in tiles, and how many tiles its ends fade over.
uniform float length_tiles = 6.0;
uniform float end_fade = 0.5;

vec2 cell_uv(vec2 uv, float frame) {
	float col = mod(frame, float(columns));
	float row = floor(frame / float(columns));
	return (vec2(col, row) + uv) / float(columns);
}

void fragment() {
	float position = mod(TIME * fps + time_offset, float(frames));
	float frame = floor(position);
	float next = mod(frame + 1.0, float(frames));
	// Half a texel in from the cell's edge, so neighbours never bleed in.
	vec2 inset = vec2(0.5 / 256.0);
	vec2 sample_uv = clamp(vec2(fract(UV.x + tile_offset), UV.y), inset, 1.0 - inset);
	float heat = mix(texture(flipbook, cell_uv(sample_uv, frame)).r,
			texture(flipbook, cell_uv(sample_uv, next)).r, position - frame);
	float ends = min(UV.x, length_tiles - UV.x);
	heat *= smoothstep(0.0, end_fade, ends);
	vec3 color = mix(tip_color, body_color, smoothstep(0.05, 0.35, heat));
	color = mix(color, core_color, smoothstep(0.55, 0.95, heat));
	ALBEDO = color * heat * intensity;
	ALPHA = clamp(heat * opacity, 0.0, 1.0);
}
