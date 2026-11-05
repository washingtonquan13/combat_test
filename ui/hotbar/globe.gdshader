shader_type canvas_item;
// A Diablo-style resource globe (dock.gd's HP and FP globes): the
// TextureRect's texture masked to a circle and seen through a glass sphere.
// Below `fill` it is "liquid": full colour, optionally tinted, slowly
// swirling and refracted. Above it the texture is drained to grey. A wavy
// meniscus moves along the surface, and a gloss highlight, a fresnel edge
// and a metal rim sell the glass.
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
// Swirl: how much the flowing noise brightens/darkens the liquid, how far it
// bends the texture, and how fast it flows.
uniform float swirl = 0.25;
uniform float refract = 0.006;
uniform float swirl_speed = 1.0;
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
uniform vec2 uv_scale = vec2(1.0);
uniform vec2 uv_offset = vec2(0.0);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * noise(p);
		p = p * 2.03 + vec2(1.7, 9.2);
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
	// The sphere's surface normal facing the viewer.
	float z = sqrt(max(0.0, 1.0 - r * r));

	float t = TIME * swirl_speed;
	// Domain-warped noise: liquid that flows and curls instead of sliding.
	vec2 q = UV * 3.0;
	vec2 warp = vec2(fbm(q + vec2(0.0, t * 0.15)), fbm(q + vec2(5.2, -t * 0.12)));
	float flow = fbm(q + warp * 2.0 + vec2(t * 0.08, -t * 0.2));

	// The meniscus: two travelling sine waves, flattened at empty and full.
	float wt = TIME * wave_speed;
	float wave = sin(UV.x * 9.0 + wt * 1.7) * 0.6 + sin(UV.x * 17.0 - wt * 2.3) * 0.4;
	float settle = smoothstep(0.0, 0.04, fill) * smoothstep(1.0, 0.96, fill);
	float level = fill + wave * wave_amp * settle;

	float height = 1.0 - UV.y;
	float line_px = fwidth(UV.y);
	float wet = 1.0 - smoothstep(level - line_px, level + line_px, height);
	if (fill <= 0.0) {
		wet = 0.0;
	}

	vec2 bend = (warp - vec2(0.5)) * refract * wet;
	vec4 base = texture(TEXTURE, uv_offset + (UV + bend) * uv_scale);

	// Liquid: the texture in full colour, tinted, rippling with the flow.
	float depth = fill > 0.0 ? clamp(height / max(level, 0.001), 0.0, 1.0) : 0.0;
	vec4 tint = mix(liquid_bottom, liquid_top, depth);
	vec3 liquid = mix(base.rgb, tint.rgb, tint.a);
	liquid *= 1.0 + swirl * (flow - 0.5) * 2.0;

	// Drained: the same texture gone grey and dim.
	float lum = dot(base.rgb, vec3(0.299, 0.587, 0.114));
	vec3 empty = mix(base.rgb, vec3(lum), empty_desaturate) * empty_dim;

	vec3 col = mix(empty, liquid, wet);

	float surface = 1.0 - smoothstep(0.0, surface_px * line_px, abs(height - level));
	if (fill > 0.001 && fill < 0.999) {
		col = mix(col, surface_color.rgb, surface * surface_color.a);
	}

	// Glass sphere: darker toward the edge, a cool fresnel glow just inside
	// the rim, and a soft gloss highlight up and to the left.
	col *= mix(1.0, 0.35 + 0.65 * z, sphere_shade);
	col += fresnel_color.rgb * fresnel_color.a * pow(r, 4.0);
	vec2 g = (c - vec2(-0.14, -0.22)) * vec2(1.0, 1.6);
	float spec = 1.0 - smoothstep(0.0, 0.22, length(g));
	col += vec3(1.0) * gloss * spec * spec;

	float rim_w = rim_px * px;
	float rim = smoothstep(1.0 - rim_w - px, 1.0 - rim_w, r);
	// A little bevel: the rim brighter at the top than at the bottom.
	vec3 rim_col = rim_color.rgb * (0.75 + 0.5 * (0.5 - UV.y));
	col = mix(col, rim_col, rim * rim_color.a);

	COLOR = vec4(col, inside * base.a);
}
