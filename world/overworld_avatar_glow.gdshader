shader_type spatial;
// The avatar's glow: a soft oval of its colour behind it, always facing
// the camera, so the icon seems to give off light. The overworld has no
// bloom, so the glow has to be drawn. A billboard rather than a grown
// copy of the body, which cracks apart along the low-poly icon's facets.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

instance uniform vec3 body_color : source_color = vec3(0.82, 0.86, 0.92);
instance uniform float pulse_depth = 0.4;
instance uniform float pulse_rate = 2.4;
uniform float strength = 0.55;
uniform float push_back = 0.8;

void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0] * length(MODEL_MATRIX[0].xyz),
		INV_VIEW_MATRIX[1] * length(MODEL_MATRIX[1].xyz),
		INV_VIEW_MATRIX[2] * length(MODEL_MATRIX[2].xyz),
		MODEL_MATRIX[3]);
	// Set back behind the icon, so the body stands in front of its glow.
	MODELVIEW_MATRIX[3].z -= push_back;
}

void fragment() {
	float d = length((UV - 0.5) * 2.0);
	float glow = pow(clamp(1.0 - d, 0.0, 1.0), 2.2);
	float pulse = 1.0 - pulse_depth * (0.5 - 0.5 * cos(TIME * pulse_rate));
	ALBEDO = body_color * glow * strength * pulse;
}
