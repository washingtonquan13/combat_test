shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, specular_disabled;

// Blades carry an upward normal so a clump lights like the ground under it.
// Their colour is the ground's own grass layer under the clump, graded as the
// ground shader grades it, so grass grows out of the ground instead of sitting
// on it as a separate carpet. Tips are lighter, and straw in dry patches.
// INSTANCE color is per-clump variation. UV.y is 0 at the root, 1 at the tip;
// UV.x is a per-blade random number; UV2 is the blade's half-width offset.
//
// Far away a 3 cm blade is thinner than a pixel and flickers, so blades widen
// to stay min_px wide, and with distance a share of them fold away while the
// rest widen to keep the same cover. Past fade_start they sink into the ground.

uniform sampler2D ground_grass : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D ground_soil : source_color, filter_linear_mipmap, repeat_enable;
uniform float grass_tile = 0.33;
uniform vec3 dry_tip = vec3(0.58, 0.54, 0.27);
uniform float wind = 0.05;
uniform float min_px = 1.6;
uniform float max_widen = 4.0;
uniform float thin_start = 8.0;
uniform float fade_start = 30.0;
uniform float fade_end = 44.0;

varying float tip;
varying vec3 base;
varying vec3 top;

float lum(vec3 c) {
	return dot(c, vec3(0.33));
}

void vertex() {
	tip = UV.y;
	vec3 origin = MODEL_MATRIX[3].xyz;

	vec3 g = textureLod(ground_grass, origin.xz * grass_tile, 5.0).rgb;
	g = mix(vec3(lum(g)), g, 1.2) * vec3(0.5, 0.68, 0.36);
	float macro = textureLod(ground_soil, origin.xz * 0.031, 0.0).g;
	g *= mix(0.86, 1.14, smoothstep(0.08, 0.34, macro));
	float dry = smoothstep(0.38, 0.62, textureLod(ground_soil, origin.xz * 0.013 + vec2(0.37, 0.71), 0.0).r);
	base = g * COLOR.rgb * 0.8;
	top = mix(g * vec3(1.45, 1.5, 1.15), dry_tip, dry * 0.55) * COLOR.rgb;

	float dist = length((VIEW_MATRIX * vec4(origin, 1.0)).xyz);
	float metres_per_px = dist * 2.0 / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float blade_w = 0.03 * length(MODEL_MATRIX[0].xyz);
	float keep = mix(1.0, 0.4, smoothstep(thin_start, fade_start, dist));
	float alive = clamp((keep - UV.x) / 0.08, 0.0, 1.0);
	float widen = min(max(1.0, min_px * metres_per_px / blade_w) / keep, max_widen);
	VERTEX.xz += UV2 * (widen - 1.0);

	float sink = 1.0 - smoothstep(fade_start, fade_end, dist);
	VERTEX.xz = mix(VERTEX.xz - UV2 * widen, VERTEX.xz, alive);
	VERTEX.y *= alive * sink;

	float sway = sin(TIME * 1.3 + origin.x * 0.7 + origin.z * 0.5) + 0.5 * sin(TIME * 2.9 + origin.x * 1.9);
	float bend = UV.y * UV.y;
	VERTEX.x += sway * wind * bend;
	VERTEX.z += sway * wind * 0.6 * bend;
	NORMAL = (inverse(MODEL_MATRIX) * vec4(0.0, 1.0, 0.0, 0.0)).xyz;
}

void fragment() {
	ALBEDO = mix(base, top, tip);
	ROUGHNESS = 0.85;
	AO = mix(0.85, 1.0, tip);
	AO_LIGHT_AFFECT = 0.3;
	BACKLIGHT = top * 0.3 * tip;
}
