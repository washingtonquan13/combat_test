shader_type canvas_item;

// The terminal page's glow, drawn into Terminal's small GlowViewport: a
// gaussian blur of the page at a quarter of its resolution. crt_screen
// adds it back over the sharp page as the light the phosphor throws
// around itself. A real blur, not a few offset taps on the glass: taps
// that few showed as faint copies of every letter instead of a glow.

uniform sampler2D page_tex : source_color, filter_linear, repeat_disable;
// Spread of the glow, in output texels (one is two design pixels).
uniform float sigma = 2.2;

void fragment() {
	// One output texel is 4x4 page texels. Each tap is four bilinear reads,
	// each the average of a 2x2 block, so a tap sees the whole 4x4 block:
	// a thin stroke never falls between taps and shimmers as it moves.
	vec2 page_texel = 1.0 / vec2(textureSize(page_tex, 0));
	vec3 sum = vec3(0.0);
	float total = 0.0;
	for (int y = -4; y <= 4; y++) {
		for (int x = -4; x <= 4; x++) {
			vec2 o = vec2(float(x), float(y));
			float w = exp(-dot(o, o) / (2.0 * sigma * sigma));
			vec2 at = UV + o * SCREEN_PIXEL_SIZE;
			vec3 block = texture(page_tex, at + page_texel * vec2(-1.0, -1.0)).rgb
					+ texture(page_tex, at + page_texel * vec2(1.0, -1.0)).rgb
					+ texture(page_tex, at + page_texel * vec2(-1.0, 1.0)).rgb
					+ texture(page_tex, at + page_texel * vec2(1.0, 1.0)).rgb;
			sum += block * 0.25 * w;
			total += w;
		}
	}
	COLOR = vec4(sum / total, 1.0);
}
