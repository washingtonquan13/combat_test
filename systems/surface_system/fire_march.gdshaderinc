// The march shared by every live fire volume (fire_volume.gdshader, the
// wall; fire_breath.gdshader, the breath): each pixel's ray is walked
// across the volume's box, stopping at whatever's in front, gathering the
// light the flame gives off and losing what it blocks. The including
// shader defines fire_heat(p, flash) before including this: how hot the
// flame is at p, in the model's space (0..1), and how hard it flashes.

uniform int steps = 48;
// Light given off and light blocked per unit flame per meter.
uniform float emission = 2.2;
uniform float absorption = 2.5;
// How much a flash turns the flame toward the core colour.
uniform float flash_color = 0.7;
uniform vec3 core_color : source_color = vec3(1.0, 0.85, 0.55);
uniform vec3 body_color : source_color = vec3(1.0, 0.42, 0.08);
uniform vec3 tip_color : source_color = vec3(0.6, 0.07, 0.02);
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;

varying vec3 v_camera;
varying vec3 v_local;

void vertex() {
	v_local = VERTEX;
	v_camera = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
}

vec3 fire_color(float heat, float flash) {
	vec3 color = mix(tip_color, body_color, smoothstep(0.05, 0.35, heat));
	color = mix(color, core_color, smoothstep(0.55, 0.95, heat));
	return mix(color, core_color, flash * flash_color);
}

// The light and coverage of the fire in a box of size extent round the
// model's origin, along this pixel's ray.
vec4 march_fire(vec3 extent, vec2 screen_uv, vec2 frag_coord, mat4 model, mat4 inv_view, mat4 inv_projection) {
	vec3 half_size = extent * 0.5;
	vec3 dir = normalize(v_local - v_camera);
	vec3 inv = 1.0 / dir;
	vec3 t0 = (-half_size - v_camera) * inv;
	vec3 t1 = (half_size - v_camera) * inv;
	vec3 lo = min(t0, t1);
	vec3 hi = max(t0, t1);
	float t_near = max(max(max(lo.x, lo.y), lo.z), 0.0);
	float t_far = min(min(hi.x, hi.y), hi.z);
	// Stop at whatever's in front: the ground, a unit. This is the only
	// depth test - the box's far faces may lie under the ground.
	float depth = textureLod(depth_texture, screen_uv, 0.0).r;
	vec4 view = inv_projection * vec4(screen_uv * 2.0 - 1.0, depth, 1.0);
	vec3 world = (inv_view * vec4(view.xyz / view.w, 1.0)).xyz;
	vec3 scene_local = (inverse(model) * vec4(world, 1.0)).xyz;
	t_far = min(t_far, dot(scene_local - v_camera, dir));
	float step_len = (t_far - t_near) / float(steps);
	if (step_len <= 0.0) {
		return vec4(0.0);
	}
	// Jitter where each ray starts, so the steps don't show as bands.
	float jitter = fract(sin(dot(frag_coord, vec2(12.9898, 78.233))) * 43758.5453);
	vec3 light = vec3(0.0);
	float transmit = 1.0;
	for (int i = 0; i < steps; i++) {
		vec3 p = v_camera + dir * (t_near + (float(i) + jitter) * step_len);
		float flash;
		float heat = fire_heat(p, flash);
		if (heat > 0.003) {
			light += transmit * fire_color(heat, flash) * heat * emission * step_len;
			transmit *= exp(-heat * absorption * step_len);
			if (transmit < 0.02) {
				break;
			}
		}
	}
	return vec4(light, 1.0 - transmit);
}
