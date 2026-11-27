shader_type spatial;
render_mode unshaded, cull_back, fog_disabled;

// The terminal's glass: the SubViewport's 2D page drawn as a curved,
// scanlined phosphor tube. Unshaded, so the screen reads as light given off,
// not light caught, in a dark room as much as a lit one.

uniform sampler2D screen_tex : source_color, filter_linear;
// Lines the page is drawn with (the SubViewport's height).
uniform float lines = 480.0;
// How far the glass bulges: 0 is flat.
uniform float curvature = 0.12;
uniform float scanline_strength = 0.35;
uniform float vignette = 0.55;
uniform float flicker = 0.03;
uniform float brightness = 1.35;
// The tube's own faint glow where nothing is drawn.
uniform vec3 base_glow : source_color = vec3(0.012, 0.03, 0.016);

vec2 bend(vec2 uv) {
	vec2 c = uv * 2.0 - 1.0;
	c *= 1.0 + curvature * dot(c, c) * 0.5;
	return c * 0.5 + 0.5;
}

void fragment() {
	vec2 uv = bend(UV);
	// Past the bent edge is the tube's black rim.
	float inside = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
	vec3 col = texture(screen_tex, uv).rgb;
	// A soft bleed: the phosphor glows a little into its neighbours.
	vec2 px = vec2(1.0 / (lines * 4.0 / 3.0), 1.0 / lines);
	col += 0.25 * (texture(screen_tex, uv + vec2(px.x, 0.0)).rgb + texture(screen_tex, uv - vec2(px.x, 0.0)).rgb);
	col /= 1.5;
	// One dark line per two page rows: at one per row the pattern sits at
	// two screen pixels from the reading position and shimmers (moire).
	float scan_lines = lines * 0.5;
	float scan = 0.5 + 0.5 * cos(uv.y * scan_lines * 6.2831853);
	// Further off, a pixel spans more lines still; the pattern fades out
	// before it gets that fine.
	float lines_per_pixel = fwidth(uv.y * scan_lines);
	col *= 1.0 - scanline_strength * scan * (1.0 - smoothstep(0.25, 0.5, lines_per_pixel));
	vec2 e = uv * (1.0 - uv);
	col *= mix(1.0, pow(clamp(e.x * e.y * 16.0, 0.0, 1.0), 0.35), vignette);
	col *= 1.0 - flicker * (0.5 + 0.5 * sin(TIME * 47.0));
	col = col * brightness + base_glow;
	// Capped at white, so the glass never feeds the glow pass more than a
	// lit page would.
	ALBEDO = min(col, vec3(1.0)) * inside;
}
