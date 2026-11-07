shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, specular_schlick_ggx;
#include "res://systems/surface_system/water_wall.gdshaderinc"

// The Wall of Water's wave (water_wall.gd): a tidal wave held as it curls.
// UV.x runs along the wall in metres, UV.y along the cross-section in
// metres from the back foot, up the long back, over the crest, round the
// lip, back under it and down the face to the trough, so water scrolling
// in +UV.y climbs the back, pours over the lip and runs down the face,
// forever. The surface is glassy: chop stretched the way the water runs
// bends what it reflects (a sky of its own, as the levels have none) into
// light and dark streaks, and what's behind shows through, bent. Thick
// water is dark slate; where it thins under the crest and out to the lip
// the light comes through it teal. `crackle` (Electrified Wall of Water)
// runs a Voronoi web of lightning through the water, the electrified
// ground's look.

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D ripples : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec3 deep_color : source_color = vec3(0.06, 0.13, 0.17);
uniform vec3 thin_color : source_color = vec3(0.05, 0.45, 0.42);
// The sky it reflects: toward the zenith, at the horizon, its clouds, and
// the sea below the horizon.
uniform vec3 zenith_color : source_color = vec3(0.18, 0.25, 0.32);
uniform vec3 horizon_color : source_color = vec3(0.44, 0.5, 0.55);
uniform vec3 cloud_color : source_color = vec3(0.92, 0.93, 0.95);
uniform vec3 ground_color : source_color = vec3(0.1, 0.17, 0.21);
// How far the chop tilts the surface.
uniform float chop = 0.16;
// How far it bends what's behind, as a fraction of the screen.
uniform float refraction = 0.03;
// How far the swells stand out, metres.
uniform float churn = 0.1;
uniform float crackle = 0.0;
uniform vec3 crackle_color : source_color = vec3(0.45, 0.7, 1.0);
uniform float crackle_energy = 6.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

vec2 hash2(vec2 p) {
	return vec2(hash(p), hash(p + vec2(17.3, 41.9)));
}

// Distance to the nearest edge between Voronoi cells: thin bright lines
// where it is near 0.
float voronoi_edge(vec2 p, float t) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 nearest = vec2(8.0);
	vec2 cell = vec2(0.0);
	float best = 8.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 g = vec2(float(x), float(y));
			vec2 o = 0.5 + 0.5 * sin(t + 6.2831 * hash2(i + g));
			vec2 r = g + o - f;
			float d = dot(r, r);
			if (d < best) {
				best = d;
				nearest = r;
				cell = g;
			}
		}
	}
	float edge = 8.0;
	for (int y = -2; y <= 2; y++) {
		for (int x = -2; x <= 2; x++) {
			vec2 g = cell + vec2(float(x), float(y));
			vec2 o = 0.5 + 0.5 * sin(t + 6.2831 * hash2(i + g));
			vec2 r = g + o - f;
			if (dot(nearest - r, nearest - r) > 0.00001) {
				edge = min(edge, dot(0.5 * (nearest + r), normalize(r - nearest)));
			}
		}
	}
	return edge;
}

// The sky in world direction r.
vec3 sky(vec3 r) {
	vec3 c = mix(horizon_color, zenith_color, smoothstep(0.0, 0.7, r.y));
	vec2 p = r.xz / max(r.y + 0.3, 0.05) * 0.12;
	float cloud = texture(streaks, p).r;
	c = mix(c, cloud_color, smoothstep(0.55, 0.8, cloud) * smoothstep(-0.05, 0.25, r.y) * 0.25);
	return mix(ground_color, c, smoothstep(-0.3, 0.1, r.y));
}

void vertex() {
	SETTLE_VERTEX
	// Long swells riding the flow, none at the feet, which sit on the
	// ground.
	float feet = smoothstep(0.0, 0.08, share) * smoothstep(1.0, 0.9, share);
	float swell_big = textureLod(streaks, vec2(UV.x * 0.3, UV.y * 0.12 - TIME * flow_speed * 0.12), 0.0).r - 0.5;
	float swell_small = textureLod(streaks, vec2(UV.x * 0.9 + 0.4, UV.y * 0.3 - TIME * flow_speed * 0.3), 0.0).r - 0.5;
	VERTEX += NORMAL * (swell_big + swell_small * 0.5) * churn * feet * height;
}

void fragment() {
	float t = TIME * flow_speed;
	// Chop, its ridges drawn out the way the water runs, and broad swells
	// under it.
	vec3 n1 = texture(ripples, vec2(UV.x * 1.4, UV.y * 0.5 - t * 0.5)).rgb * 2.0 - 1.0;
	vec3 n2 = texture(ripples, vec2(UV.x * 0.45 + 0.3, UV.y * 0.15 - t * 0.15)).rgb * 2.0 - 1.0;
	vec3 n3 = texture(ripples, vec2(UV.x * 3.0 + 0.7, UV.y * 1.4 - t * 1.4)).rgb * 2.0 - 1.0;
	vec2 tilt = (n1.xy * 0.6 + n2.xy * 0.9 + n3.xy * 0.3) * chop;
	vec3 n = normalize(NORMAL + TANGENT * tilt.x + BINORMAL * tilt.y);
	NORMAL = n;

	vec3 world_n = (INV_VIEW_MATRIX * vec4(n, 0.0)).xyz;
	vec3 world_view = (INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz;
	vec3 reflected = sky(reflect(-world_view, world_n));
	float facing = clamp(dot(n, VIEW), 0.0, 1.0);
	float fresnel = 0.04 + 0.66 * pow(1.0 - facing, 5.0);

	// Thin water, lit through teal; thick water, dark.
	float thin = 1.0 - smoothstep(0.08, 0.9, thickness);
	vec3 water = mix(deep_color, thin_color, thin);
	vec2 bend = tilt * refraction * (0.4 + height * 0.6);
	vec3 behind = textureLod(screen_texture, SCREEN_UV + bend, 0.0).rgb;
	vec3 tint = mix(vec3(0.2, 0.35, 0.42), vec3(0.45, 0.85, 0.8), thin);

	ALBEDO = water * 0.5;
	ROUGHNESS = 0.06;
	SPECULAR = 0.5;
	BACKLIGHT = thin_color * thin;
	EMISSION = reflected * fresnel + (water * 1.1 + behind * tint * mix(0.3, 0.5, thin) + thin_color * thin * 0.3) * (1.0 - fresnel);
	// Fades into the ground at both feet, so there's no seam.
	float alpha = 0.95 * smoothstep(0.0, 0.03, share) * smoothstep(1.0, 0.86, share);

	if (crackle > 0.0) {
		// Only patches of the wall carry a charge at a time, wandering.
		vec2 p = UV * 0.8;
		float patch = smoothstep(0.55, 0.7, texture(streaks, UV * 0.08 + vec2(TIME * 0.05, -TIME * 0.11)).r);
		float flick = step(0.3, hash(floor(vec2(TIME * 14.0, floor(p.x * 0.7)))));
		float e = voronoi_edge(p + vec2(0.0, -t * 0.3), TIME * 2.0);
		float line = smoothstep(0.035, 0.0, e) * patch * (0.3 + 0.7 * flick);
		EMISSION += crackle_color * crackle_energy * line * crackle;
		alpha = max(alpha, line * crackle);
	}
	ALPHA = alpha * strength * smoothstep(0.0, 0.15, height);
}
