shader_type canvas_item;
render_mode blend_disabled, unshaded;

// world/render_time.gd: the left pixel holds the bits of TIME, the right
// one the bits of the frame number the CPU set for this frame, a byte per
// channel. The viewport is HDR, so 0-255 stay exact and unclamped.

uniform float frame;

void fragment() {
	uint bits = floatBitsToUint(UV.x < 0.5 ? TIME : frame);
	COLOR = vec4(float(bits & 255u), float((bits >> 8u) & 255u), float((bits >> 16u) & 255u), float(bits >> 24u));
}
