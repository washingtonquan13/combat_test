// Shared by the raymarched cone volumes (lightning_cone_volume.gdshader,
// frost_mist.gdshader). The mesh is a unit BoxMesh (size 1) that
// cone_box() stretches to bound the cone, so the node's origin is the
// cone's tip (the hand) and the cone runs along its local -Z. Because the
// vertices move, the MeshInstance3D needs a custom_aabb.
//
// Each shader's vertex() does:
//     VERTEX = cone_box(VERTEX);
//     local_vertex = VERTEX;
//     local_camera = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
// and its fragment() marches local_camera + dir * t for t in the span
// cone_span() gives.

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
// The cone's shape, in the node's local metres: how far it reaches along
// -Z, and its half-angle in radians. (Not "length": that is a built-in.)
uniform float cone_length = 9.0;
uniform float half_angle = 0.45;

varying vec3 local_vertex;
varying vec3 local_camera;

// Stretches the unit box to bound the cone: x and y out to the far end's
// radius, z from the hand (0) to the far end (-cone_length).
vec3 cone_box(vec3 v) {
	float radius = tan(half_angle) * cone_length * 1.02;
	return vec3(v.xy * 2.0 * radius, (v.z - 0.5) * cone_length);
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

// The span of the camera ray, in the direction `dir`, to march: inside the
// cone, in front of the camera, and short of whatever the scene has in
// front (the ground, a unit), read from the depth texture. That is the only
// depth test, since the box's far faces may lie under the ground. Pass the
// fragment built-ins, which a function cannot reach.
bool cone_span(vec3 dir, vec2 screen_uv, mat4 inv_projection, mat4 inv_view, mat4 model, out float t_in, out float t_out) {
	if (!cone_interval(local_camera, dir, t_in, t_out)) {
		return false;
	}
	t_in = max(t_in, 0.0);
	float scene_depth = textureLod(depth_texture, screen_uv, 0.0).r;
	vec4 view = inv_projection * vec4(screen_uv * 2.0 - 1.0, scene_depth, 1.0);
	vec3 world = (inv_view * vec4(view.xyz / view.w, 1.0)).xyz;
	vec3 scene_local = (inverse(model) * vec4(world, 1.0)).xyz;
	t_out = min(t_out, dot(scene_local - local_camera, dir));
	return t_out > t_in;
}

// A per-pixel random 0..1, to jitter where each ray starts so the steps
// don't show as bands.
float cone_jitter(vec2 frag_coord) {
	return fract(sin(dot(frag_coord, vec2(12.9898, 78.233))) * 43758.5453);
}
