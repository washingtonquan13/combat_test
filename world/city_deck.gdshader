// The city overworld's bridge decks, ramps, rails and piers, in their
// vertex colours, with a hole cut round the player: the camera looks
// steeply down, so a deck above the avatar would hide it. Everything more
// than `clearance` above the avatar's feet and within `radius` of it
// across the ground is dithered away, the edge soft.
shader_type spatial;
render_mode cull_back;

// Set every frame by the active OverworldAvatar.
global uniform vec3 player_position;
uniform float clearance = 2.6;
uniform float radius = 7.0;
uniform float feather = 2.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (world_pos.y > player_position.y + clearance) {
		float d = distance(world_pos.xz, player_position.xz);
		float keep = clamp((d - radius + feather) / feather, 0.0, 1.0);
		// A 4x4 Bayer threshold, so the edge dissolves instead of
		// sorting as transparency.
		ivec2 p = ivec2(FRAGCOORD.xy) % 4;
		int bayer[16] = int[](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
		if (keep < (float(bayer[p.y * 4 + p.x]) + 0.5) / 16.0) {
			discard;
		}
	}
	// The builder's vertex colours are sRGB.
	ALBEDO = pow(COLOR.rgb, vec3(2.2));
	ROUGHNESS = 0.95;
}
