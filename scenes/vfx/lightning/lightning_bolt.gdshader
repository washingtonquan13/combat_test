shader_type spatial;
// One lightning channel drawn as a ribbon that always faces the camera.
// The mesh (built by lightning_arcs.gd) puts both edge vertices of each
// point at the same spot on the channel:
//   NORMAL    the channel's direction at that point
//   UV.x      -1 or +1, which side of the channel this vertex is on
//   UV2.x     the ribbon's half width, in metres
//   COLOR.r   weight: how bright this point is relative to the channel
//   COLOR.g   reveal coordinate, e.g. the drop from the cloud. A strike
//             grows by comparing it against the `reveal` uniform
//   COLOR.b   1 on a branch, 0 on the main channel
// The vertex shader pushes the two vertices apart sideways, across the
// view, so the ribbon is always seen face on. Additive, unshaded, and
// brighter than 1.0, so the environment's glow blooms it.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled, skip_vertex_transform;

uniform vec3 core_color : source_color = vec3(0.92, 0.95, 1.0);
uniform vec3 glow_color : source_color = vec3(0.45, 0.55, 1.0);
// Half width of the white-hot core, metres. Never thinner than a pixel.
uniform float core_half_width = 0.03;
uniform float core_strength = 6.0;
uniform float glow_strength = 1.2;
// How fast the halo fades toward the ribbon's edge.
uniform float glow_falloff = 2.5;
// Brightness of the main channel and of the branches, set per frame.
uniform float main_brightness = 1.0;
uniform float branch_brightness = 1.0;
// How far down the channel is drawn, 0..1 of drop (the stepped leader).
uniform float reveal = 1.0;
// Extra brightness at the leader's tip while it is still coming down.
uniform float tip_strength = 0.0;

varying float half_width;
varying float pixel_size;
varying float energy;

void vertex() {
	vec3 p = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 t = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 side = cross(t, normalize(p));
	float side_len = length(side);
	// A channel pointing straight at the camera has no sideways: use any.
	side = side_len > 1e-4 ? side / side_len : vec3(1.0, 0.0, 0.0);
	// World size of one pixel at this depth.
	pixel_size = 2.0 * max(-p.z, 0.01) / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float wanted = UV2.x;
	// Keep the ribbon at least a few pixels wide so a far bolt does not
	// crawl, and dim it by the same factor so it does not get brighter.
	half_width = max(wanted, 3.0 * pixel_size);
	energy = wanted / half_width;
	VERTEX = p + side * UV.x * half_width;
	NORMAL = vec3(0.0, 0.0, 1.0);
}

void fragment() {
	float drop = COLOR.g;
	if (drop > reveal) {
		discard;
	}
	float across = abs(UV.x) * half_width;
	float core_w = max(core_half_width, 0.75 * pixel_size);
	float core = 1.0 - smoothstep(core_w * 0.5, core_w, across);
	// The core's light is spread over core_w: a pixel-clamped core dims.
	core *= core_half_width / core_w;
	float halo = pow(max(1.0 - abs(UV.x), 0.0), glow_falloff);
	float brightness = COLOR.r * mix(main_brightness, branch_brightness, COLOR.b);
	float tip = tip_strength * smoothstep(reveal - 0.04, reveal, drop);
	vec3 colour = core_color * core * core_strength + glow_color * halo * glow_strength;
	ALBEDO = colour * (brightness + tip) * energy;
}
