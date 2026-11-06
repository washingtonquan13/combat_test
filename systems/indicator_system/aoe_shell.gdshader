shader_type spatial;
// AoE volume preview: an almost clear shell whose edge glows where it is
// seen side-on (fresnel) and where it cuts through scene geometry (scene
// depth vs the shell's own depth). The cut line is the footprint: it lands
// on floors, walls, steps and bridges at their real height, so an AoE
// aimed in the air and one sitting on the ground share one look.
// Needs Forward+ or Mobile: Compatibility has no depth texture.
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec4 tint : source_color = vec4(0.86, 0.9, 0.95, 1.0);
// Opacity of the shell's face, its side-on rim, and the cut line.
uniform float face_alpha = 0.015;
uniform float rim_alpha = 0.3;
uniform float rim_power = 4.0;
uniform float cut_alpha = 1.0;
// Cut line half-width in metres, and the soft glow that trails it.
uniform float cut_width = 0.05;
uniform float cut_glow = 0.35;
uniform float cut_glow_alpha = 0.2;
// Slow bands drifting up the shell; zero turns them off.
uniform float shimmer_alpha = 0.025;
uniform float shimmer_scale = 2.5;
uniform float shimmer_speed = 0.35;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float raw = texture(depth_tex, SCREEN_UV).r;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, raw, 1.0);
	float scene_dist = -view.z / view.w;
	float shell_dist = -VERTEX.z;
	// Distance along the view ray from this shell fragment to whatever
	// opaque surface is behind it. Small = the shell is touching it.
	float gap = max(scene_dist - shell_dist, 0.0);
	float cut = 1.0 - smoothstep(cut_width * 0.5, cut_width, gap);
	float glow = exp(-gap / max(cut_glow, 0.001)) * cut_glow_alpha;

	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float rim = pow(1.0 - facing, rim_power) * rim_alpha;

	float bands = 0.5 + 0.5 * sin((world_pos.y + world_pos.x * 0.3) * shimmer_scale - TIME * shimmer_speed * 6.2831);
	float shimmer = bands * bands * shimmer_alpha;

	float a = max(max(cut * cut_alpha, glow), face_alpha + rim + shimmer);
	ALBEDO = mix(tint.rgb, vec3(1.0), cut * 0.5);
	ALPHA = clamp(a * tint.a, 0.0, 1.0);
}
