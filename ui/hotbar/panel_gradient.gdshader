shader_type canvas_item;
// The dock panel's face (dock.tscn Backdrop): a top-to-bottom gradient
// inside a rounded rectangle, drawn just inside the PanelContainer's own
// border so the border and shadow stay a StyleBoxFlat.

uniform vec4 top_color : source_color = vec4(0.165, 0.141, 0.11, 1.0);
uniform vec4 bottom_color : source_color = vec4(0.082, 0.071, 0.055, 1.0);
uniform float radius_px = 5.0;

void fragment() {
	vec2 size = 1.0 / fwidth(UV);
	vec2 p = UV * size;
	vec2 half_size = size * 0.5;
	vec2 q = abs(p - half_size) - (half_size - vec2(radius_px));
	float d = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius_px;
	vec4 col = mix(top_color, bottom_color, UV.y);
	col.a *= clamp(0.5 - d, 0.0, 1.0);
	COLOR = col;
}
