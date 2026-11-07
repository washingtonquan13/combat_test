shader_type spatial;
// The overworld avatar's body: solid alignment colour, lit so its facets
// read, with a rim that glows and a slow pulse. The colour and the pulse
// come from overworld_avatar.gd per instance.

instance uniform vec3 body_color : source_color = vec3(0.82, 0.86, 0.92);
// 0 = steady, 1 = the glow dips all the way out at the bottom of a pulse.
instance uniform float pulse_depth = 0.4;
instance uniform float pulse_rate = 2.4;
uniform float face_glow = 0.12;
uniform float rim_glow = 1.1;
uniform float rim_power = 2.5;

void fragment() {
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), rim_power);
	float pulse = 1.0 - pulse_depth * (0.5 - 0.5 * cos(TIME * pulse_rate));
	ALBEDO = body_color;
	ROUGHNESS = 0.3;
	SPECULAR = 0.7;
	EMISSION = body_color * (face_glow + rim_glow * rim) * pulse;
}
