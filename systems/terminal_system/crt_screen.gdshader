shader_type spatial;
render_mode cull_back, fog_disabled;

// The terminal's glass: the SubViewport's 2D page drawn as a curved,
// scanlined phosphor tube behind a sheet of real glass. The page is
// EMISSION, so it reads as light given off in a dark room as much as a lit
// one; the surface itself is near-black, glossy and non-metallic, so the
// scene's lights and sky leave faint highlights and reflections on it.

uniform sampler2D screen_tex : source_color, filter_linear, repeat_disable;
// The page is laid out on a 640x480 design grid and drawn at whatever
// resolution the SubViewport has (TerminalScreen scales its layout to fit).
// Scanlines and the bleed are measured in design rows, not texels, so a
// sharper SubViewport sharpens the text without changing the tube's look.
uniform float design_lines = 480.0;
// How far the glass bulges: 0 is flat.
uniform float curvature = 0.12;
// The tube's rounded corners, as a fraction of its half-height.
uniform float corner_radius = 0.16;
uniform float scanline_strength = 0.35;
uniform float vignette = 0.55;
uniform float brightness = 1.35;
// The tube's own faint glow where nothing is drawn.
uniform vec3 base_glow : source_color = vec3(0.012, 0.03, 0.016);
// Soft light around bright text (a ring blur of the page added back). Done
// here rather than left to the environment's glow, which differs per area.
uniform float halo_strength = 0.25;
// Fed every frame by Terminal: 1.0 at rest, dipping with the tube's
// flicker. The same number drives the ScreenLight, so the glass and the
// spill it throws never disagree.
uniform float glow_gain = 1.0;
// Fed by Terminal from TerminalScreen: how fast the page scrolls, in page
// heights per second (+ is the text moving up). The phosphor lags behind
// moving text, leaving a brief ghost trail.
uniform float scroll_velocity = 0.0;
// The part of the page that scrolls (x0, y0, x1, y1 in page UV), also fed
// by Terminal. Only it trails: a smear over the whole page also ghosted
// the header and footer, which never moved.
uniform vec4 scroll_rect = vec4(0.0);
// How long the phosphor holds a lit dot, in seconds; sets the trail length.
// About a frame and a half: longer, and the taps part into visible copies
// of each line instead of a smear.
uniform float persistence = 0.025;
// A slow bright band rolling down the tube, and per-frame grain.
uniform float roll_strength = 0.05;
uniform float noise_strength = 0.035;
// The glass. Reflections must stay faint at reading distance: in daylight
// the default 4% (SPECULAR 0.5) put the sky's horizon and a sharp SSR copy
// of the trees across the page. 0.2 is about 1.6%, and the roughness
// keeps what is reflected soft.
uniform float glass_specular = 0.2;
uniform float glass_roughness = 0.15;
uniform float smudge_roughness = 0.22;

const float ASPECT = 4.0 / 3.0;

vec2 bend(vec2 uv) {
	vec2 c = uv * 2.0 - 1.0;
	c *= 1.0 + curvature * dot(c, c) * 0.5;
	return c * 0.5 + 0.5;
}

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

// Rounded-rectangle distance, negative inside.
float rounded_box(vec2 p, vec2 half_size, float r) {
	vec2 q = abs(p) - half_size + r;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

vec3 page(vec2 uv) {
	return texture(screen_tex, uv).rgb;
}

void fragment() {
	vec2 uv = bend(UV);
	// The tube's face: a rounded rectangle in the bent space, so the corners
	// curve with the glass. Its edge is antialiased by its own screen-space
	// width; past it is the tube's black rim.
	vec2 c = (uv * 2.0 - 1.0) * vec2(ASPECT, 1.0);
	float edge = rounded_box(c, vec2(ASPECT, 1.0), corner_radius);
	float aa = max(fwidth(edge), 1e-4);
	float inside = 1.0 - smoothstep(-aa, aa, edge);

	// One design pixel, in UV.
	vec2 px = vec2(1.0 / (design_lines * ASPECT), 1.0 / design_lines);
	vec3 col = page(uv);
	// Two rings around this point, staggered: the halo, and (the inner one)
	// the far-away fallback below. A single ring drew a hard outline at its
	// radius instead of a glow that falls off.
	vec3 ring = vec3(0.0);
	vec3 outer = vec3(0.0);
	for (int i = 0; i < 6; i++) {
		float a = float(i) * 1.0471976;
		ring += page(uv + vec2(cos(a), sin(a)) * px * 1.6);
		outer += page(uv + vec2(cos(a + 0.5236), sin(a + 0.5236)) * px * 3.6);
	}
	ring /= 6.0;
	outer /= 6.0;
	// The SubViewport has no mipmaps, so a far glass would sample one texel
	// in many and sparkle; once a screen pixel spans several texels, the
	// ring stands in for the filtered average.
	float texels_per_pixel = fwidth(uv.y) * float(textureSize(screen_tex, 0).y);
	col = mix(col, (col + ring * 6.0) / 7.0, smoothstep(1.5, 4.0, texels_per_pixel));
	// A soft bleed: the phosphor glows a little into its neighbours.
	col += 0.25 * (page(uv + vec2(px.x, 0.0)) + page(uv - vec2(px.x, 0.0)));
	col /= 1.5;
	col += (ring * 0.4 + outer * 0.6) * halo_strength;

	// Afterglow: this point still shows, fading, what was here a moment ago,
	// which has since moved by the scroll. Capped so a fast fling smears a
	// line, not the page. Taps that land outside the scrolling area add
	// nothing, so the rules and the header don't bleed into the trail.
	float trail = clamp(scroll_velocity * persistence, -0.03, 0.03);
	bool in_body = uv.x >= scroll_rect.x && uv.x <= scroll_rect.z
			&& uv.y >= scroll_rect.y && uv.y <= scroll_rect.w;
	if (in_body && abs(trail) > 0.0005) {
		vec3 ghost = vec3(0.0);
		// Six fixed taps show as a comb of copies; jittered per pixel they
		// blend into one smear. The jitter changes every frame, or it is a
		// fixed dither that stipples the smear into streaks.
		float jitter = hash(FRAGCOORD.xy * 0.731 + fract(TIME * 7.13) * vec2(91.0, 53.0));
		for (int i = 1; i <= 6; i++) {
			float k = (float(i) - jitter) / 6.0;
			float y = uv.y - trail * k;
			float weight = (1.0 - k * 0.8) * step(scroll_rect.y, y) * step(y, scroll_rect.w);
			ghost += page(vec2(uv.x, y)) * weight;
		}
		// Faint: at 0.1 the six taps added a third of the page's brightness
		// and the text was hard to read mid-glide.
		col += ghost * 0.05;
	}

	// One dark line per two design rows: at one per row the pattern sits at
	// two screen pixels from the reading position and shimmers (moire).
	float scan_lines = design_lines * 0.5;
	float scan = 0.5 + 0.5 * cos(uv.y * scan_lines * 6.2831853);
	// Further off, a pixel spans more lines still; the pattern fades out
	// before it gets that fine.
	float lines_per_pixel = fwidth(uv.y * scan_lines);
	col *= 1.0 - scanline_strength * scan * (1.0 - smoothstep(0.25, 0.5, lines_per_pixel));
	vec2 e = uv * (1.0 - uv);
	col *= mix(1.0, pow(clamp(e.x * e.y * 16.0, 0.0, 1.0), 0.35), vignette);

	// The roll band: a wide soft bar drifting down every ~16 s.
	float band_at = fract(TIME * 0.06) * 1.6 - 0.3;
	float band = exp(-pow((uv.y - band_at) * 7.0, 2.0));
	col *= 1.0 + roll_strength * band;
	col += base_glow * band;
	// Grain, new each frame, at screen pixels so it never beats with the
	// scanlines or the text.
	float grain = hash(FRAGCOORD.xy + floor(TIME * 60.0) * vec2(37.0, 17.0)) - 0.5;
	col *= 1.0 + noise_strength * grain;

	col *= glow_gain;
	col = col * brightness + base_glow * (1.0 + grain * 0.5);
	// Capped at white, so the glass never feeds the glow pass more than a
	// lit page would. Reflections come on top and are left uncapped: they
	// are the scene's own light.
	EMISSION = min(col, vec3(1.0)) * inside;

	// The glass: near-black, glossy, with faint smudges and dust that dull
	// the reflection in patches. Fixed to the unbent UV, so they sit on the
	// surface, not in the picture.
	float smudge = value_noise(UV * vec2(5.0, 3.75)) * 0.6 + value_noise(UV * vec2(13.0, 9.75)) * 0.4;
	smudge = smoothstep(0.5, 0.85, smudge);
	float dust = smoothstep(0.7, 0.95, value_noise(UV * vec2(64.0, 48.0)));
	ALBEDO = vec3(0.012);
	METALLIC = 0.0;
	SPECULAR = glass_specular;
	ROUGHNESS = mix(0.55, glass_roughness + smudge_roughness * smudge + 0.12 * dust, inside);
	// Tilt the flat quad's normal outwards from the centre, so highlights
	// and reflections curve with the tube instead of lying flat on it.
	vec2 n = (UV * 2.0 - 1.0) * curvature * 1.5;
	NORMAL = normalize(NORMAL + TANGENT * n.x - BINORMAL * n.y);
}
