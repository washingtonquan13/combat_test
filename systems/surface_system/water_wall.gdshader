shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, specular_schlick_ggx;
#include "res://systems/surface_system/water_wall.gdshaderinc"

// The Wall of Water's wave (water_wall.gd): a breaking wave held at its
// peak. UV.x runs along the wall in metres, UV.y along the cross-section
// in metres from the back foot, up over the crest, round the lip, back
// under it and down the face to the front foot, so water scrolling in
// +UV.y climbs the back, pours over the lip and falls down the face,
// forever. Bulges ride the flow (the vertex shader pushes them out along
// the normal), two ripple normal maps run with it, and the colour comes
// from how thick the water is: dark and nearly solid at the base, bright
// and lit through where the curl thins out. What's behind shows through,
// bent. `crackle` (Electrified Wall of Water) runs a Voronoi web of
// lightning through the water, the electrified ground's look.

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D ripples : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D foam_cells : filter_linear_mipmap, repeat_enable;
uniform vec3 deep_color : source_color = vec3(0.01, 0.1, 0.16);
uniform vec3 shallow_color : source_color = vec3(0.1, 0.55, 0.58);
uniform vec3 foam_color : source_color = vec3(0.86, 0.94, 0.96);
// What the surface reflects at a grazing angle: the levels have no sky.
uniform vec3 reflect_color : source_color = vec3(0.45, 0.58, 0.66);
// How far it bends what's behind, as a fraction of the screen.
uniform float refraction = 0.025;
// How far the bulges stand out, metres.
uniform float churn = 0.16;
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

// Where along the cross-section (CUSTOM1.x) the crest and lip are, and
// the feet: water_wall.gd's PROFILE.
const float CREST_FROM = 0.34;
const float CREST_TO = 0.6;

void vertex() {
	SETTLE_VERTEX
	// Bulges riding down the flow, none at the feet, which sit on the
	// ground; finer, sharper ones tear at the crest.
	float feet = smoothstep(0.0, 0.08, share) * smoothstep(1.0, 0.9, share);
	float swell_big = textureLod(streaks, vec2(UV.x * 0.3, UV.y * 0.2 - TIME * flow_speed * 0.2), 0.0).r - 0.5;
	float swell_small = textureLod(streaks, vec2(UV.x * 0.9 + 0.4, UV.y * 0.6 - TIME * flow_speed * 0.6), 0.0).r - 0.5;
	float crest = smoothstep(CREST_FROM - 0.06, CREST_FROM + 0.04, share) * smoothstep(CREST_TO + 0.04, CREST_TO - 0.06, share);
	VERTEX += NORMAL * (swell_big * churn + swell_small * churn * (0.35 + 0.35 * crest)) * feet * height;
}

void fragment() {
	vec2 flow = vec2(UV.x * 0.35, UV.y * 0.25 - TIME * flow_speed * 0.25);
	float a = texture(streaks, flow).r;
	float b = texture(streaks, flow * vec2(1.7, 0.6) + vec2(0.37, -TIME * flow_speed * 0.12)).r;
	float run = a * 0.6 + b * 0.4;

	vec3 n1 = texture(ripples, vec2(UV.x * 0.45, UV.y * 0.35 - TIME * flow_speed * 0.35)).rgb;
	vec3 n2 = texture(ripples, vec2(UV.x * 1.1 + 0.3, UV.y * 0.9 - TIME * flow_speed * 0.9)).rgb;
	NORMAL_MAP = normalize((n1 + n2) - 1.0) * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 1.0;

	// Foam, as cells carried with the water: thick on the crest and round
	// the lip, churning at both feet, in streaks running down the face.
	float cells = texture(foam_cells, vec2(UV.x * 1.1, UV.y * 0.8 - TIME * flow_speed * 0.8)).r;
	float crest = smoothstep(CREST_FROM, CREST_FROM + 0.08, share) * smoothstep(CREST_TO + 0.02, CREST_TO - 0.06, share);
	float feet = smoothstep(0.06, 0.0, share) + smoothstep(0.92, 1.0, share);
	float face = smoothstep(0.62, 0.9, share);
	// Down the face it runs in long streaks, not blobs.
	float lace = texture(foam_cells, vec2(UV.x * 1.4, UV.y * 0.18 - TIME * flow_speed * 0.18)).r;
	// Only where it rolls over the lip does it whiten, in a narrow line;
	// over the top it runs clear.
	float roll = smoothstep(0.47, 0.53, share) * smoothstep(0.63, 0.57, share);
	float cover = roll * (0.55 + 0.45 * run) + crest * smoothstep(0.62, 0.75, run) * 0.4 + feet * 0.9;
	float foam = smoothstep(1.0 - cover, 1.0 - cover + 0.25, cells) * clamp(cover * 1.6, 0.0, 1.0);
	foam = max(foam, smoothstep(0.72, 0.85, lace) * face * smoothstep(0.5, 0.65, run) * 0.7);

	float facing = abs(dot(NORMAL, VIEW));
	float fresnel = pow(1.0 - facing, 4.0);
	// Thin water, lit through; thick water, dark.
	float thin = 1.0 - smoothstep(0.12, 1.1, thickness);
	vec3 water = mix(deep_color, shallow_color, thin * (0.75 + 0.25 * run));

	vec2 bend = (vec2(run, b) - 0.5) * refraction * (0.4 + height * 0.6);
	vec3 behind = textureLod(screen_texture, SCREEN_UV + bend, 0.0).rgb;

	ALBEDO = mix(water * 0.6, foam_color, foam);
	ROUGHNESS = mix(0.04, 0.75, foam);
	SPECULAR = 0.6;
	BACKLIGHT = shallow_color * thin * (1.0 - foam);
	// What's behind, tinted the deeper the water; light through the thin
	// water; and the sky it would reflect, at a grazing angle.
	vec3 tint = mix(vec3(0.15, 0.45, 0.55), vec3(0.45, 0.85, 0.9), thin);
	EMISSION = (behind * tint * 0.5 + shallow_color * thin * 0.3 + reflect_color * fresnel * 0.5) * (1.0 - foam);
	// Foam is lit through by the light it scatters, even in shade.
	EMISSION += foam_color * foam * 0.35;
	float body = mix(0.5, 0.9, smoothstep(0.2, 1.2, thickness));
	float alpha = max(max(body, fresnel), foam * 0.95);

	if (crackle > 0.0) {
		// Only patches of the wall carry a charge at a time, wandering.
		vec2 p = UV * 0.8;
		float patch = smoothstep(0.55, 0.7, texture(streaks, UV * 0.08 + vec2(TIME * 0.05, -TIME * 0.11)).r);
		float flick = step(0.3, hash(floor(vec2(TIME * 14.0, floor(p.x * 0.7)))));
		float e = voronoi_edge(p + vec2(0.0, -TIME * flow_speed * 0.3), TIME * 2.0);
		float line = smoothstep(0.035, 0.0, e) * patch * (0.3 + 0.7 * flick);
		EMISSION += crackle_color * crackle_energy * line * crackle;
		alpha = max(alpha, line * crackle);
	}
	ALPHA = alpha * strength * smoothstep(0.0, 0.15, height);
}
