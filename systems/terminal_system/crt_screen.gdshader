shader_type spatial;
render_mode cull_back, fog_disabled;

// The terminal's glass: the SubViewport's 2D page drawn as a curved,
// scanlined phosphor tube behind a sheet of real glass. The page is
// EMISSION, so it reads as light given off in a dark room as much as a lit
// one; the surface itself is near-black, glossy and non-metallic, so the
// scene's lights and sky leave faint highlights and reflections on it.

uniform sampler2D screen_tex : source_color, filter_linear, repeat_disable;
// The page blurred (Terminal's GlowViewport, terminal_glow.gdshader).
uniform sampler2D glow_tex : source_color, filter_linear, repeat_disable;
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
// Soft light around bright text (glow_tex added back). Done here rather
// than left to the environment's glow, which differs per area.
uniform float halo_strength = 0.9;
// Fed every frame by Terminal: 1.0 at rest, dipping with the tube's
// flicker. The same number drives the ScreenLight, so the glass and the
// spill it throws never disagree.
uniform float glow_gain = 1.0;
// The tube's disturbances, all fed by Terminal (see its _process), as
// Fallout 4's Pip-Boy settings name them: a burst is a brief flash when
// the picture changes; shudder shakes the rows sideways; vertical hold
// rolls the whole picture up through the tube (0..1 is one full roll); the
// scan line is a thin bright line sweeping down the tube's face, at scan_at
// (face UV, <0 for none). noise_seed changes every frame and stays in 0..1,
// so the hash keeps its precision; TIME does not after a few minutes.
uniform float burst = 0.0;
uniform float shudder = 0.0;
uniform float vhold = 0.0;
uniform float scan_at = -1.0;
uniform float scan_strength = 0.12;
uniform float noise_seed = 0.0;
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

// Where on the page the tube is showing this point: the vertical hold
// slides the picture up and wraps it, and shudder shifts each row a
// little sideways. The tube's face, scanlines and vignette stay put.
vec2 picture(vec2 uv) {
	vec2 p = uv;
	p.y = fract(p.y - vhold);
	float row = floor(uv.y * 160.0);
	p.x += shudder * 0.12 * (hash(vec2(row * 0.37, noise_seed * 97.0)) - 0.5);
	// Kept on the page: past its edge the sampler smears the last texel.
	p.x = clamp(p.x, 0.0, 1.0);
	return p;
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

	vec2 face_uv = uv;
	uv = picture(uv);
	vec3 col = page(uv);
	vec3 glow = texture(glow_tex, uv).rgb;
	// The SubViewport has no mipmaps, so a far glass would sample one texel
	// in many and sparkle; once a screen pixel spans several texels, the
	// glow (the page already filtered) stands in for it.
	float texels_per_pixel = fwidth(face_uv.y) * float(textureSize(screen_tex, 0).y);
	col = mix(col, glow, smoothstep(2.0, 6.0, texels_per_pixel));
	// Glow is light thrown into the dark around lit text. Where the
	// surroundings are lit too (inside the highlight bar) it would only fill
	// the dark letters cut out of the bar and wash them out, so it fades
	// away as the blurred page gets bright.
	float around = dot(glow, vec3(0.3, 0.59, 0.11));
	col += glow * halo_strength * (1.0 - smoothstep(0.2, 0.6, around));

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
	float scan = 0.5 + 0.5 * cos(face_uv.y * scan_lines * 6.2831853);
	// Further off, a pixel spans more lines still; the pattern fades out
	// before it gets that fine.
	float lines_per_pixel = fwidth(face_uv.y * scan_lines);
	col *= 1.0 - scanline_strength * scan * (1.0 - smoothstep(0.25, 0.5, lines_per_pixel));
	vec2 e = face_uv * (1.0 - face_uv);
	col *= mix(1.0, pow(clamp(e.x * e.y * 16.0, 0.0, 1.0), 0.35), vignette);

	// The roll band: a wide soft bar drifting down every ~16 s.
	float band_at = fract(TIME * 0.06) * 1.6 - 0.3;
	float band = exp(-pow((face_uv.y - band_at) * 7.0, 2.0));
	col *= 1.0 + roll_strength * band;
	col += base_glow * band;
	// The scan line: thin and bright, with a short soft tail above it. Its
	// core widens to at least a pixel and a half, dimming to match, so on a
	// far glass it stays one soft line instead of popping in and out.
	if (scan_at >= 0.0) {
		float d = face_uv.y - scan_at;
		float w = max(1.0 / 260.0, fwidth(face_uv.y) * 1.5);
		float line = exp(-pow(d / w, 2.0)) * (1.0 / 260.0) / w + 0.35 * exp(d * 40.0) * step(d, 0.0);
		// Lit text under it brightens; the black lifts to a faint line.
		col += (col * 4.0 + normalize(base_glow) * 0.5) * line * scan_strength;
	}
	// A burst flashes the halo round the text and lifts the black. It adds
	// the blurred page rather than scaling the picture: lit cores are near
	// the cap, and scaling them pushed red and blue up under a clipped
	// green, turning the flash cyan-white.
	col += glow * burst * 0.8 + base_glow * burst * 6.0;
	// Grain, new each frame, at screen pixels so it never beats with the
	// scanlines or the text.
	float grain = hash(FRAGCOORD.xy + noise_seed * vec2(91.0, 53.0)) - 0.5;
	col *= 1.0 + noise_strength * grain;

	col *= glow_gain;
	col = col * brightness + base_glow * (1.0 + grain * 0.5);
	// Capped at white, so the glass never feeds the glow pass more than a
	// lit page would. Reflections come on top and are left uncapped: they
	// are the scene's own light.
	// While the picture rolls, the gap between frames (the blanking bar)
	// passes through as a black band, over everything the tube adds.
	float blank = 1.0;
	if (vhold > 0.0) {
		blank = smoothstep(0.0, 0.04, uv.y) * smoothstep(1.0, 0.96, uv.y);
	}
	EMISSION = min(col, vec3(1.0)) * inside * blank;

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
