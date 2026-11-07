shader_type spatial;
render_mode unshaded, depth_draw_never, cull_disabled, shadows_disabled;

// The shimmer over a fire.tscn: an upright quad that turns to face the
// camera and redraws what's behind it, nudged by noise rising through
// it. Drawn before the flames (render_priority) so it never wipes them.
// `burning` (set by fire_surface.gd) fades it as the fire goes out.

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
// How far it bends the picture, as a fraction of the screen.
uniform float strength = 0.006;
uniform float rise_speed = 1.2;
instance uniform float burning = 1.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

void vertex() {
	vec3 up = vec3(0.0, 1.0, 0.0);
	vec3 to_camera = INV_VIEW_MATRIX[3].xyz - MODEL_MATRIX[3].xyz;
	vec3 right = normalize(cross(up, to_camera));
	vec3 world = MODEL_MATRIX[3].xyz + right * VERTEX.x + up * VERTEX.y;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
}

void fragment() {
	// QuadMesh UV runs top to bottom; height runs base (0) to top (1).
	float height = 1.0 - UV.y;
	float mask = (1.0 - smoothstep(0.5, 1.0, abs(UV.x * 2.0 - 1.0)))
			* smoothstep(0.0, 0.15, height) * (1.0 - smoothstep(0.45, 1.0, height));
	vec2 q = UV * vec2(7.0, 5.0) + vec2(0.0, TIME * rise_speed * 3.0);
	vec2 bend = vec2(noise(q), noise(q + 5.3)) - 0.5;
	ALBEDO = textureLod(screen_texture, SCREEN_UV + bend * strength * mask * burning, 0.0).rgb;
	ALPHA = mask * burning;
}
