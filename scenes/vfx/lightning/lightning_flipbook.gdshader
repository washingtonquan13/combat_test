shader_type spatial;
// lightning_bolt.gdshader's ribbon, painted with a frame of a lightning
// flipbook (tools/lightning_flipbook.py) instead of a computed core and
// halo. The arc itself can be near straight: the zigzag and the small
// forks are in the picture. Same mesh as the bolt shader, plus:
//   UV2.y     which frame this arc shows
// Each frame is a bolt running left (the arc's start) to right (its end),
// its ends at the frame's vertical middle. The texture's channels:
//   R  the white-hot core      G  the soft glow around it
// Additive, unshaded, and brighter than 1.0, so it blooms.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled, skip_vertex_transform;

uniform sampler2D flipbook : filter_linear_mipmap, repeat_disable;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
// Fades the ribbon out this close (metres) to what is behind it, so a
// wide ribbon passing into the floor or a wall does not show a hard cut.
uniform float soft_distance = 0.35;
// The atlas's grid of frames.
uniform int columns = 2;
uniform int rows = 8;
uniform vec3 core_color : source_color = vec3(0.92, 0.95, 1.0);
uniform vec3 glow_color : source_color = vec3(0.45, 0.55, 1.0);
uniform float core_strength = 4.0;
uniform float glow_strength = 1.4;
// Brightness of the main arcs and of the branches, set per frame.
uniform float main_brightness = 1.0;
uniform float branch_brightness = 1.0;
// How far along the arcs are drawn, 0..1 (see lightning_arcs.gd).
uniform float reveal = 1.0;
// Extra brightness at the growing tip.
uniform float tip_strength = 0.0;

varying float energy;
varying flat int frame;

void vertex() {
	vec3 p = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 t = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 side = cross(t, normalize(p));
	float side_len = length(side);
	side = side_len > 1e-4 ? side / side_len : vec3(1.0, 0.0, 0.0);
	float pixel_size = 2.0 * max(-p.z, 0.01) / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	// The painted bolt fills about a third of the frame's height: keep it
	// a few pixels tall, dimmed to match, so a far arc does not vanish.
	float wanted = UV2.x;
	float half_width = max(wanted, 8.0 * pixel_size);
	energy = wanted / half_width;
	frame = int(UV2.y + 0.5);
	VERTEX = p + side * UV.x * half_width;
	NORMAL = vec3(0.0, 0.0, 1.0);
}

void fragment() {
	float drop = COLOR.g;
	if (drop > reveal) {
		discard;
	}
	int count = columns * rows;
	int f = ((frame % count) + count) % count;
	vec2 cell = vec2(float(f % columns), float(f / columns));
	vec2 size = vec2(1.0 / float(columns), 1.0 / float(rows));
	// Along the arc is the frame's width, across it the height. Kept off
	// the frame's border so a neighbouring frame never bleeds in.
	vec2 inner = clamp(vec2(UV.y, UV.x * 0.5 + 0.5), vec2(0.002, 0.01), vec2(0.998, 0.99));
	vec2 paint = texture(flipbook, (cell + inner) * size).rg;
	float brightness = COLOR.r * mix(main_brightness, branch_brightness, COLOR.b);
	float tip = tip_strength * smoothstep(reveal - 0.04, reveal, drop);
	vec3 colour = core_color * paint.r * core_strength + glow_color * paint.g * glow_strength;
	float depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec4 behind = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float gap = VERTEX.z - behind.z / behind.w;
	float soft = clamp(gap / soft_distance, 0.0, 1.0);
	ALBEDO = colour * (brightness + tip) * energy * soft;
}
