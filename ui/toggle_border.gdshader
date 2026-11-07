shader_type canvas_item;
// A line running round the edge of a hotbar slot whose toggle is on
// (hotbar_slot.gd): a faint border all the way round, with bright heads
// chasing each other along it, each trailing a fading tail.

uniform vec4 line_color : source_color = vec4(1.0, 0.85, 0.2, 1.0);
uniform vec4 base_color : source_color = vec4(1.0, 0.85, 0.2, 0.25);
uniform float thickness_px = 2.0;
// Laps per second.
uniform float speed = 0.5;
// How much of the gap between heads a tail covers, 0..1.
uniform float segment = 0.6;
uniform int heads = 2;

void fragment() {
	vec2 px = fwidth(UV);
	vec2 size = 1.0 / px;
	vec2 p = UV * size;
	float left = p.x;
	float right = size.x - p.x;
	float top = p.y;
	float bottom = size.y - p.y;
	float edge = min(min(left, right), min(top, bottom));
	float band = clamp(thickness_px - edge + 0.5, 0.0, 1.0);

	// Distance along the border, clockwise from the top-left corner.
	float s;
	if (edge == top) {
		s = p.x;
	} else if (edge == right) {
		s = size.x + p.y;
	} else if (edge == bottom) {
		s = 2.0 * size.x + size.y - p.x;
	} else {
		s = 2.0 * (size.x + size.y) - p.y;
	}
	float t = s / (2.0 * (size.x + size.y));

	// 0 at a head, rising behind it.
	float behind = fract((TIME * speed - t) * float(heads));
	float trail = pow(clamp(1.0 - behind / segment, 0.0, 1.0), 2.0);

	vec4 color = mix(base_color, line_color, trail);
	COLOR = vec4(color.rgb, color.a * band);
}
