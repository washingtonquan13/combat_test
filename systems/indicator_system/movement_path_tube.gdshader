shader_type spatial;
// The movement path as BG3 draws it: a thin ray-traced tube, not a ribbon.
//
// Each path segment is one box (MovementIndicator builds them). For every
// pixel the box covers, the fragment shader casts the view ray against
// the infinite cylinder around the segment's axis, clips it by the two
// miter planes the segment shares with its neighbours (so the pieces
// partition the tube exactly and blending composes one tube),
// and integrates 8 samples along the ray's path through the tube:
// - brightness is the ray's chord through the tube over its diameter,
//   so the centre is brightest and the edges fall to nothing;
// - the first and last fade_start / fade_end metres of the path fade in
//   and out (squared);
// - dash patterns (on, off metres) scroll along path distance, lerped
//   start to end of each segment, for obscured stretches;
// - behind scene geometry the line keeps 10% (BG3's floor), read from
//   the depth texture, since depth testing is off.
// A tube thinner than min_pixel_radius on screen is widened to that and
// dimmed by the same ratio, so it stays a steady thin line at tactical
// zoom instead of breaking up into sub-pixel dots.
//
// Per-segment data, one value for all 8 corners of its box:
// CUSTOM0 = A.xyz, path distance at A
// CUSTOM1 = B.xyz, path distance at B
// CUSTOM2 = miter plane normal at A (pointing A->B), unused
// CUSTOM3 = miter plane normal at B (pointing A->B), unused
// COLOR = segment colour (linear), UV = (on, off) at A, UV2 = (on, off) at B

render_mode unshaded, blend_premul_alpha, depth_draw_never, depth_test_disabled, cull_disabled, shadows_disabled, world_vertex_coords;

uniform float radius = 0.0125;
uniform float min_pixel_radius = 0.9;
uniform float total_length = 1.0;
uniform float fade_start = 1.0;
uniform float fade_end = 1.0;
uniform float anim_speed = 1.0;
uniform vec2 pulse_limits = vec2(0.1, 0.4);
uniform float pulse_speed = 1.0;
uniform float brightness = 2.0;
uniform float occluded_floor = 0.1;
uniform float dash_weight = 0.8;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;

varying flat vec4 v_a;
varying flat vec4 v_b;
varying flat vec3 v_n0;
varying flat vec3 v_n1;
varying flat vec4 v_pattern;
varying flat vec4 v_color;
varying vec3 v_world;

// World size of one pixel at view depth `depth`.
float pixel_size(float depth, mat4 projection, vec2 viewport) {
	bool ortho = projection[3][3] > 0.5;
	return (ortho ? 2.0 : 2.0 * depth) / (projection[1][1] * viewport.y);
}

void vertex() {
	v_a = CUSTOM0;
	v_b = CUSTOM1;
	v_n0 = CUSTOM2.xyz;
	v_n1 = CUSTOM3.xyz;
	v_pattern = vec4(UV, UV2);
	v_color = COLOR;

	// Rebuild the box around the axis at the radius this pixel scale
	// needs, with room past each end for the miter planes to lean out.
	vec3 a = CUSTOM0.xyz;
	vec3 b = CUSTOM1.xyz;
	vec3 axis = b - a;
	float len = max(length(axis), 1e-4);
	vec3 u = axis / len;
	vec3 side = cross(u, vec3(0.0, 1.0, 0.0));
	side = length(side) < 1e-3 ? vec3(1.0, 0.0, 0.0) : normalize(side);
	vec3 up = cross(side, u);

	vec3 rel = VERTEX - a;
	bool at_b = dot(rel, u) > len * 0.5;
	float sx = sign(dot(rel, side));
	float sy = sign(dot(rel, up));
	vec3 end = at_b ? b : a;
	float depth = max(-(VIEW_MATRIX * vec4(end, 1.0)).z, 0.01);
	float r = max(radius, pixel_size(depth, PROJECTION_MATRIX, VIEWPORT_SIZE) * min_pixel_radius) * 1.5;
	VERTEX = end + u * (at_b ? 4.0 : -4.0) * r + side * sx * r + up * sy * r;
}

void fragment() {
	// Exactly one fragment per pixel per box, whichever way it is wound.
	if (FRONT_FACING) {
		discard;
	}

	vec3 ro;
	vec3 rd;
	if (PROJECTION_MATRIX[3][3] > 0.5) {
		ro = (INV_VIEW_MATRIX * vec4(VERTEX.xy, 0.0, 1.0)).xyz;
		rd = normalize((INV_VIEW_MATRIX * vec4(0.0, 0.0, -1.0, 0.0)).xyz);
	} else {
		ro = CAMERA_POSITION_WORLD;
		rd = normalize((INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz - ro);
	}

	vec3 a = v_a.xyz;
	vec3 b = v_b.xyz;
	vec3 axis = b - a;
	float len = length(axis);
	if (len < 1e-4) {
		discard;
	}
	vec3 u = axis / len;

	float px = pixel_size(max(-VERTEX.z, 0.01), PROJECTION_MATRIX, VIEWPORT_SIZE);
	float r = max(radius, px * min_pixel_radius);
	float thinness = radius / r;

	// View ray against the infinite cylinder around AB.
	vec3 oc = ro - a;
	float card = dot(u, rd);
	float caoc = dot(u, oc);
	float qa = 1.0 - card * card;
	if (qa < 1e-6) {
		discard;
	}
	float qb = dot(oc, rd) - caoc * card;
	float qc = dot(oc, oc) - caoc * caoc - r * r;
	float h = qb * qb - qa * qc;
	if (h < 0.0) {
		discard;
	}
	h = sqrt(h);
	float t0 = (-qb - h) / qa;
	float t1 = (-qb + h) / qa;

	// Clip by the miter plane at A (keep the B side) and at B (keep the
	// A side).
	float d0 = dot(rd, v_n0);
	float f0 = dot(oc, v_n0);
	if (abs(d0) < 1e-6) {
		if (f0 < 0.0) { discard; }
	} else if (d0 > 0.0) {
		t0 = max(t0, -f0 / d0);
	} else {
		t1 = min(t1, -f0 / d0);
	}
	float d1 = dot(rd, v_n1);
	float f1 = dot(ro - b, v_n1);
	if (abs(d1) < 1e-6) {
		if (f1 > 0.0) { discard; }
	} else if (d1 < 0.0) {
		t0 = max(t0, -f1 / d1);
	} else {
		t1 = min(t1, -f1 / d1);
	}
	t0 = max(t0, 0.0);
	if (t1 <= t0) {
		discard;
	}

	// Path distance and pattern where the ray enters and leaves.
	vec3 p_in = ro + rd * t0;
	vec3 p_out = ro + rd * t1;
	float f_in = clamp(dot(p_in - a, u) / len, 0.0, 1.0);
	float f_out = clamp(dot(p_out - a, u) / len, 0.0, 1.0);
	float s_in = mix(v_a.w, v_b.w, f_in);
	float s_out = mix(v_a.w, v_b.w, f_out);

	float anim = TIME * anim_speed;
	float sum = 0.0;
	for (int k = 0; k < 8; k++) {
		float w = float(k) / 7.0;
		float s = mix(s_in, s_out, w);
		vec2 pattern = mix(v_pattern.xy, v_pattern.zw, mix(f_in, f_out, w));
		float env = clamp(s / fade_start, 0.0, 1.0) * clamp((total_length - s) / fade_end, 0.0, 1.0);
		float period = pattern.x + pattern.y;
		float dash = 1.0;
		if (pattern.y > 0.0 && period > 0.0) {
			float on = step(mod(s - anim, period), pattern.x);
			dash = 1.0 - dash_weight * (1.0 - on);
		}
		sum += env * env * dash;
	}
	float body = sum * 0.125;

	// Centre-bright: the share of the full diameter the ray crosses here.
	float chord = (t1 - t0) * 0.5 / r;

	float wave = 0.5 + 0.5 * sin(TIME * pulse_speed * TAU);
	float pulse = 1.0 - mix(pulse_limits.x, pulse_limits.y, wave);

	// 10% behind walls and floors, like BG3.
	float scene = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec4 scene_view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, scene, 1.0);
	float scene_depth = -scene_view.z / scene_view.w;
	float tube_depth = -(VIEW_MATRIX * vec4(p_in, 1.0)).z;
	float seen = (1.0 - clamp((tube_depth - scene_depth) * 10.0, 0.0, 1.0)) * (1.0 - occluded_floor) + occluded_floor;

	// Premultiplied, so crimson reads as crimson on a light floor instead
	// of washing out the way an additive colour would.
	float opacity = clamp(body * chord * pulse * seen * thinness * v_color.a, 0.0, 1.0);
	ALBEDO = v_color.rgb * brightness * opacity;
	ALPHA = opacity;
}
