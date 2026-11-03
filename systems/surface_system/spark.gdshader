shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

// One spark over a fire.tscn: a tiny bright dot facing the camera that
// twinkles as it rises. COLOR (the particle's colour ramp) cools and
// fades it over its life.

uniform float intensity = 4.0;
uniform float twinkle_speed = 23.0;

varying float v_seed;

void vertex() {
	float scale = length(MODEL_MATRIX[0].xyz);
	vec3 world = MODEL_MATRIX[3].xyz + (INV_VIEW_MATRIX[0].xyz * VERTEX.x + INV_VIEW_MATRIX[1].xyz * VERTEX.y) * scale;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
	v_seed = fract(float(INSTANCE_ID) * 0.6180339) * 6.2831853;
}

void fragment() {
	float r = length(UV * 2.0 - 1.0);
	float blob = 1.0 - smoothstep(0.0, 1.0, r);
	float twinkle = 0.55 + 0.45 * sin(TIME * twinkle_speed + v_seed * 7.0);
	ALBEDO = COLOR.rgb * blob * blob * twinkle * intensity * COLOR.a;
}
