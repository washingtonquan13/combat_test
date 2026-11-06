shader_type spatial;
// The glowing body that fills an electric cone (lightning_cone.gd), as a
// real volume rather than a shell. Each pixel walks the camera ray through
// the cone and adds up the light given off along the way: a faint smooth
// blue-violet glow, and thin bright filaments - the ridges of a 3D noise,
// as in ball_lightning_core.gdshader - stretched along the cone and rushing
// outward from the hand. Whiter near the axis, brightest by the hand,
// fading along the cone and to nothing at its edge, so it never shows a
// silhouette. Additive and brighter than 1.0, so it blooms.
//
// The mesh is a unit BoxMesh (size 1). The vertex shader stretches it to
// bound the cone, so the node's origin is the hand and the cone runs along
// its local -Z. Because the shader moves the vertices, the MeshInstance3D
// needs a custom_aabb (see lightning_cone.gd) or it is culled wrongly.
//
// cull_front draws the box's far faces, so it still draws with the camera
// inside it. The march is clipped to the cone itself, and stops at whatever
// is in front (the ground, a unit) by reading the depth texture; that is the
// only depth test, since the box's far faces may lie under the ground.
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_front, fog_disabled, shadows_disabled;

uniform sampler3D noise : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;

// The cone's shape, in the node's local metres: how far it reaches along
// -Z, and its half-angle in radians. (Not "length": that is a built-in.)
uniform float cone_length = 9.0;
uniform float half_angle = 0.45;

// Set per frame: overall brightness, how far along it has spread (0..1),
// and the clock that moves the streaks.
uniform float strength = 1.0;
uniform float reveal = 1.0;
uniform float time = 0.0;
// How soft the growing front is, as a fraction of the cone's length.
uniform float reveal_softness = 0.12;
// How fast the brightness dies along the cone.
uniform float falloff = 3.5;
// Meters a second the streaks rush outward from the hand.
uniform float rush = 12.0;

// The faint smooth glow filling the body.
uniform vec3 color : source_color = vec3(0.42, 0.38, 1.0);
uniform float glow_strength = 0.35;
// The filaments: their colour out at the edge, and their colour near the
// axis, where they run white-hot.
uniform vec3 filament_color : source_color = vec3(0.55, 0.55, 1.0);
uniform vec3 filament_core_color : source_color = vec3(0.92, 0.95, 1.0);
uniform float filament_strength = 2.5;
// How thin the filaments are: higher is thinner.
uniform float filament_sharpness = 10.0;
// How tight the white runs round the axis: higher keeps it nearer.
uniform float core_tightness = 5.0;
// Noise scale across the cone (per radian of spread, so the streaks fan
// out from the hand like the cone does) and along it (per meter: lower
// makes longer streaks).
uniform float streak_across = 1.6;
uniform float streak_along = 0.08;
// Where the noise starts, so no two blasts crackle alike.
uniform vec3 noise_offset = vec3(0.0);

const int STEPS = 28;

varying vec3 local_vertex;
varying vec3 local_camera;

void vertex() {
	// Stretch the unit box to bound the cone: x and y out to the far end's
	// radius, z from the hand (0) to the far end (-cone_length).
	float radius = tan(half_angle) * cone_length * 1.02;
	VERTEX = vec3(VERTEX.xy * 2.0 * radius, (VERTEX.z - 0.5) * cone_length);
	local_vertex = VERTEX;
	local_camera = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
}

// The stretch of the ray o + t * d that lies inside the cone, between the
// hand and the far end. False if the ray misses it.
bool cone_interval(vec3 o, vec3 d, out float t_in, out float t_out) {
	// First between the planes z = 0 and z = -cone_length.
	if (abs(d.z) < 1e-6) {
		t_in = -1e6;
		t_out = 1e6;
		if (o.z > 0.0 || o.z < -cone_length) {
			return false;
		}
	} else {
		float a = -o.z / d.z;
		float b = (-cone_length - o.z) / d.z;
		t_in = min(a, b);
		t_out = max(a, b);
	}
	// Then inside x^2 + y^2 <= k^2 z^2. That is a double cone, but between
	// the planes only the -Z half counts, and the -Z half is convex, so what
	// is left is one stretch.
	float k = tan(half_angle);
	float k2 = k * k;
	float qa = d.x * d.x + d.y * d.y - k2 * d.z * d.z;
	float qb = 2.0 * (o.x * d.x + o.y * d.y - k2 * o.z * d.z);
	float qc = o.x * o.x + o.y * o.y - k2 * o.z * o.z;
	// A ray parallel to the cone's side: keep the planes' stretch; the
	// density is zero outside the cone anyway.
	if (abs(qa) > 1e-6) {
		float disc = qb * qb - 4.0 * qa * qc;
		if (disc < 0.0) {
			if (qa > 0.0) {
				return false;
			}
		} else {
			float s = sqrt(disc);
			float r0 = (-qb - s) / (2.0 * qa);
			float r1 = (-qb + s) / (2.0 * qa);
			float t1 = min(r0, r1);
			float t2 = max(r0, r1);
			if (qa > 0.0) {
				// Steeper than the cone's side: inside between the two hits.
				t_in = max(t_in, t1);
				t_out = min(t_out, t2);
			} else {
				// Shallower: inside before the first hit or after the second,
				// one in each half. Keep whichever is the -Z half.
				if (o.z + d.z * t1 < 0.0) {
					t_out = min(t_out, t1);
				} else {
					t_in = max(t_in, t2);
				}
			}
		}
	}
	return t_out > t_in;
}

// Light given off at p, in the node's local space.
vec3 glow(vec3 p, float tan_half) {
	float depth = -p.z;
	float along = depth / cone_length;
	// How far out from the axis, as a fraction of the cone's radius here.
	float rr = length(p.xy) / max(depth * tan_half, 0.05);
	// Soft to the edge: zero at the cone's side, with no crease.
	float radial = max(1.0 - rr * rr, 0.0);
	// Brightest by the hand, gone by the far end, and cut at the reveal
	// front as it grows outward.
	float fade = exp(-along * falloff) * smoothstep(1.0, 0.7, along)
		* smoothstep(reveal, reveal - reveal_softness, along);
	float weight = fade * radial;
	if (weight < 0.002) {
		return vec3(0.0);
	}
	// Noise in spread-and-distance coordinates: stretched along the cone,
	// fanning from the hand, scrolling outward. Two layers moving at
	// different speeds make the filaments flicker and twist.
	vec2 spread = p.xy / max(depth, 0.25);
	vec3 q = vec3(spread * streak_across, (depth - time * rush) * streak_along) + noise_offset;
	float a = texture(noise, q).r;
	float b = texture(noise, vec3(spread * streak_across * 1.9, (depth - time * rush * 1.4) * streak_along * 1.7)
		+ noise_offset + vec3(0.37, 0.61, 0.13)).r;
	float ridge = 1.0 - abs(mix(a, b, 0.5) * 2.0 - 1.0);
	float filament = pow(ridge, filament_sharpness);
	float white = exp(-rr * rr * core_tightness);
	vec3 filament_light = mix(filament_color, filament_core_color, white) * filament * filament_strength;
	// The glow falls off faster toward the edge than the filaments do (the
	// radial term twice), and is gently mottled by the first noise layer.
	vec3 glow_light = color * glow_strength * radial * (0.7 + 0.6 * a);
	return (glow_light + filament_light) * weight;
}

void fragment() {
	vec3 dir = normalize(local_vertex - local_camera);
	float t_in;
	float t_out;
	if (!cone_interval(local_camera, dir, t_in, t_out)) {
		discard;
	}
	t_in = max(t_in, 0.0);
	// Stop at whatever's in front.
	float scene_depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, scene_depth, 1.0);
	vec3 world = (INV_VIEW_MATRIX * vec4(view.xyz / view.w, 1.0)).xyz;
	vec3 scene_local = (inverse(MODEL_MATRIX) * vec4(world, 1.0)).xyz;
	t_out = min(t_out, dot(scene_local - local_camera, dir));
	if (t_out <= t_in) {
		discard;
	}
	float step_len = (t_out - t_in) / float(STEPS);
	// Jitter where each ray starts, so the steps don't show as bands.
	float jitter = fract(sin(dot(FRAGCOORD.xy, vec2(12.9898, 78.233))) * 43758.5453);
	float tan_half = tan(half_angle);
	vec3 total = vec3(0.0);
	for (int i = 0; i < STEPS; i++) {
		vec3 p = local_camera + dir * (t_in + (float(i) + jitter) * step_len);
		total += glow(p, tan_half) * step_len;
	}
	ALBEDO = total * strength;
}
