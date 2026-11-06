shader_type canvas_item;
// A Diablo-style resource globe (dock.gd's HP and FP globes): the
// TextureRect's texture masked to a circle and seen through a glass sphere.
// Below `fill` it is "liquid": full colour, optionally tinted, with a
// swirl pattern painted on a sphere that spins about its vertical axis, so
// the liquid reads as a rotating ball rather than a flat scroll. Above it
// the texture is drained to grey. A wavy meniscus moves along the surface,
// and a gloss highlight, a fresnel edge and a metal rim sell the glass.
//
// HP: the portrait is the texture and the liquid tint is ~0, so filling
// gives the face its colour back. FP: a dark texture and a strong blue tint.

uniform float fill : hint_range(0.0, 1.0) = 1.0;
// Liquid tint at the surface and at the bottom; alpha is how much it covers
// the texture underneath (0 for the portrait, high for FP).
uniform vec4 liquid_top : source_color = vec4(0.35, 0.56, 0.85, 0.9);
uniform vec4 liquid_bottom : source_color = vec4(0.09, 0.23, 0.47, 0.95);
// The drained part: 1 = fully grey, and how dark.
uniform float empty_desaturate : hint_range(0.0, 1.0) = 1.0;
uniform float empty_dim : hint_range(0.0, 1.0) = 0.55;
uniform vec4 surface_color : source_color = vec4(1.0, 1.0, 1.0, 0.7);
uniform float surface_px = 1.5;
// The meniscus wave, as a fraction of the globe's height.
uniform float wave_amp = 0.018;
uniform float wave_speed = 1.0;
// The spinning swirl. spin_speed is radians per second about the vertical
// axis; spin_scale is how fine the pattern is; churn is how fast the pattern
// itself evolves while it turns. swirl brightens/darkens the liquid with
// it, veins are the bright ridged filaments (alpha = strength), and
// refract is how far it bends the texture underneath.
uniform float spin_speed = 0.6;
uniform float spin_scale = 2.2;
uniform float churn = 0.15;
uniform float swirl = 0.3;
uniform vec4 vein_color : source_color = vec4(0.6, 0.85, 1.0, 0.6);
uniform float vein_sharp = 5.0;
uniform float refract = 0.0;
// Glass: the shading toward the edge, the edge glow and the top-left gloss.
uniform float sphere_shade : hint_range(0.0, 1.0) = 0.45;
uniform vec4 fresnel_color : source_color = vec4(0.8, 0.85, 1.0, 0.25);
uniform float gloss : hint_range(0.0, 1.0) = 0.35;
uniform vec4 rim_color : source_color = vec4(0.66, 0.51, 0.24, 1.0);
uniform float rim_px = 3.0;
// The part of the texture shown, so a non-square portrait still fills a
// round globe (the TextureRect itself stretches, it does not crop: its
// UV must stay the rect's 0..1 for the circle). dock.gd sets these from
// the texture's aspect: the short side whole, the long side centred
// (or, for a tall portrait, nearer the top, where the face is).
// Glass: how much the ball magnifies its middle, the colour fringe toward
// the rim, the window-shaped highlight, and the light gathered in the
// bottom of the ball after passing through it.
uniform float lens : hint_range(0.0, 0.5) = 0.18;
uniform float fringe : hint_range(0.0, 0.05) = 0.012;
uniform float highlight : hint_range(0.0, 2.0) = 0.9;
uniform float caustic : hint_range(0.0, 1.0) = 0.35;
// Where the light is, as dock.gd aims it from the mouse: a direction from
// the globe's centre, its length (0..1) how far toward the edge the
// highlight slides.
uniform vec2 glint_dir = vec2(-0.6, -0.85);
uniform vec2 uv_scale = vec2(1.0);
uniform vec2 uv_offset = vec2(0.0);

float hash(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.x + p.y) * p.z);
}

float noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	vec3 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(hash(i), hash(i + vec3(1, 0, 0)), u.x),
			mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), u.x), u.y),
		mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), u.x),
			mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), u.x), u.y),
		u.z);
}

float fbm(vec3 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * noise(p);
		p = p * 2.03 + vec3(1.7, 9.2, 4.1);
		a *= 0.5;
	}
	return v;
}

void fragment() {
	vec2 c = UV - vec2(0.5);
	float r = length(c) * 2.0;
	// Pixels per unit of r, so the rim and the edge stay crisp at any size.
	float px = fwidth(r);
	float inside = 1.0 - smoothstep(1.0 - px, 1.0, r);
	// The point on the front of the sphere under this pixel.
	float z = sqrt(max(0.0, 1.0 - r * r));
	vec3 n = vec3(c.x * 2.0, -c.y * 2.0, z);

	// Turn the sphere about its vertical axis and read the swirl there: a
	// pattern that slides fast in the middle and slow at the edges, the way
	// a spinning ball does. Domain warp so it curls instead of just sliding.
	float a = TIME * spin_speed;
	vec3 p = vec3(n.x * cos(a) + n.z * sin(a), n.y, -n.x * sin(a) + n.z * cos(a)) * spin_scale;
	vec3 drift = vec3(0.0, TIME * churn, TIME * churn * 0.7);
	vec3 warp = vec3(fbm(p + drift), fbm(p + vec3(5.2, 1.3, 2.8) - drift), 0.0);
	float flow = fbm(p + warp * 1.8 + drift * 0.5);
	float ridge = 1.0 - abs(flow * 2.0 - 1.0);
	float veins = pow(ridge, vein_sharp);

	// The meniscus: two travelling sine waves, flattened at empty and full.
	float wt = TIME * wave_speed;
	float wave = sin(UV.x * 9.0 + wt * 1.7) * 0.6 + sin(UV.x * 17.0 - wt * 2.3) * 0.4;
	float settle = smoothstep(0.0, 0.04, fill) * smoothstep(1.0, 0.96, fill);
	float level = fill + wave * wave_amp * settle;

	// The liquid line seen through the glass, magnified like the picture.
	float height = 0.5 - c.y * (1.0 - lens * (1.0 - r * r));
	float line_px = fwidth(UV.y);
	float wet = 1.0 - smoothstep(level - line_px, level + line_px, height);
	if (fill <= 0.0) {
		wet = 0.0;
	}

	vec2 bend = (warp.xy - vec2(0.5)) * refract * wet;
	// Through the glass: the ball magnifies its middle, and red and blue
	// bend a touch differently toward the rim.
	vec2 seen = c * (1.0 - lens * (1.0 - r * r));
	vec2 split = c * fringe * r * r;
	vec2 at = vec2(0.5) + seen + bend;
	vec4 base = texture(TEXTURE, uv_offset + at * uv_scale);
	base.r = texture(TEXTURE, uv_offset + (at + split) * uv_scale).r;
	base.b = texture(TEXTURE, uv_offset + (at - split) * uv_scale).b;

	// Liquid: the texture in full colour, tinted, swirling.
	float depth = fill > 0.0 ? clamp(height / max(level, 0.001), 0.0, 1.0) : 0.0;
	vec4 tint = mix(liquid_bottom, liquid_top, depth);
	vec3 liquid = mix(base.rgb, tint.rgb, tint.a);
	liquid *= 1.0 + swirl * (flow - 0.5) * 2.0;
	liquid += vein_color.rgb * vein_color.a * veins * (0.4 + 0.6 * z);

	// Drained: the same texture gone grey and dim.
	float lum = dot(base.rgb, vec3(0.299, 0.587, 0.114));
	vec3 empty = mix(base.rgb, vec3(lum), empty_desaturate) * empty_dim;

	vec3 col = mix(empty, liquid, wet);

	float surface = 1.0 - smoothstep(0.0, surface_px * line_px, abs(height - level));
	if (fill > 0.001 && fill < 0.999) {
		col = mix(col, surface_color.rgb, surface * surface_color.a);
	}

	// Glass sphere: darker toward the edge, a cool fresnel glow just inside
	// the rim.
	col *= mix(1.0, 0.35 + 0.65 * z, sphere_shade);
	col += fresnel_color.rgb * fresnel_color.a * pow(r, 4.0);
	// Light through the ball gathers in a soft crescent at the bottom.
	float crescent = smoothstep(0.55, 0.92, r) * smoothstep(0.0, 0.6, -n.y) * (1.0 - smoothstep(0.96, 1.0, r));
	col += vec3(1.0, 0.95, 0.85) * caustic * crescent * 0.6;

	// The highlight is a reflection of a window where the light is: a
	// rounded pane curved round the ball, sharp-edged as glass gives it,
	// brightest on its outer side, and a soft broad sheen round it. A small
	// second glint sits opposite, where the light leaves.
	float reach = length(glint_dir);
	vec2 dir = reach > 0.001 ? glint_dir / reach : vec2(0.0, -1.0);
	vec2 spot = glint_dir * 0.34;
	vec2 d = c - spot;
	vec2 w = vec2(dot(d, vec2(-dir.y, dir.x)), dot(d, -dir)) * vec2(1.0, 1.3);
	w.y += w.x * w.x * 2.2;
	float pane = 1.0 - smoothstep(0.05, 0.075, max(abs(w.x) * 0.8, abs(w.y) * 1.7) + length(w) * 0.2);
	pane *= clamp(0.85 - w.y * 9.0, 0.15, 1.0);
	float sheen = 1.0 - smoothstep(0.0, 0.3, length(c - spot * 0.9));
	col += vec3(1.0) * highlight * (pane * 0.55 + sheen * sheen * gloss);
	float back = 1.0 - smoothstep(0.0, 0.035, length(c + glint_dir * 0.36));
	col += vec3(1.0) * highlight * back * 0.5 * reach;

	float rim_w = rim_px * px;
	float rim = smoothstep(1.0 - rim_w - px, 1.0 - rim_w, r);
	// A little bevel: the rim brighter at the top than at the bottom.
	vec3 rim_col = rim_color.rgb * (0.75 + 0.5 * (0.5 - UV.y));
	col = mix(col, rim_col, rim * rim_color.a);

	COLOR = vec4(col, inside * base.a);
}
