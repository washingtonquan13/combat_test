shader_type spatial;
// The overworld avatar's body: solid alignment colour, lit so its facets
// read, with an edge that glows and pulses. The colour and the pulse
// come from overworld_avatar.gd per instance.

instance uniform vec3 body_color : source_color = vec3(0.55, 0.62, 0.55);
// 0 = steady, 1 = the edge glow dips all the way out at the bottom of a pulse.
instance uniform float pulse_depth = 0.4;
instance uniform float pulse_rate = 2.4;
uniform float rim_glow = 1.3;
uniform float rim_power = 3.0;

void fragment() {
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), rim_power);
	float pulse = 1.0 - pulse_depth * (0.5 - 0.5 * cos(TIME * pulse_rate));
	ALBEDO = body_color;
	ROUGHNESS = 0.3;
	SPECULAR = 0.7;
	EMISSION = body_color * rim_glow * rim * pulse;
}
