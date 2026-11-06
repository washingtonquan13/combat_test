shader_type spatial;
// The shockwave of a fireball's blast: a ring of fire racing out across the
// ground, torn by noise, with a glow on the ground inside it. Made for a
// flat PlaneMesh; animate `progress` from 0 (at the centre) to 1 (at the
// plane's edge).
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

uniform vec4 ring_color : source_color = vec4(1.0, 0.55, 0.15, 1.0);
uniform vec4 glow_color : source_color = vec4(1.0, 0.3, 0.05, 1.0);
uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform float intensity = 2.0;
// How wide the ring is, as a fraction of the plane's radius.
uniform float width = 0.12;
// How bright the ground inside the ring glows.
uniform float glow = 0.6;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 x) {
	vec2 i = floor(x);
	vec2 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x),
		mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float d = length(p);
	float a = atan(p.y, p.x);
	float n = noise(vec2(a * 4.0, d * 6.0 - TIME * 3.0)) * 0.6 + noise(vec2(a * 11.0, d * 14.0)) * 0.4;
	float w = width * (1.0 - progress * 0.5);
	float ring = smoothstep(progress - w, progress, d) * (1.0 - smoothstep(progress, progress + w * 0.35, d));
	ring *= 0.4 + n * 0.9;
	float inside = (1.0 - smoothstep(0.0, progress, d)) * glow * n;
	float fade = 1.0 - progress;
	vec3 col = ring_color.rgb * ring + glow_color.rgb * inside;
	ALBEDO = col * intensity;
	ALPHA = clamp((ring + inside) * fade, 0.0, 1.0) * step(d, 1.0);
}
