shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, specular_schlick_ggx;
#include "res://systems/surface_system/water_wall.gdshaderinc"

// The Wall of Water's wave (water_wall.gd): a wall of water forever
// running up its back, over its curl and down its face. UV.x runs along the
// wall in metres, UV.y along the cross-section in metres from the back
// foot, so water scrolling in +UV.y climbs the back, rolls over the lip and
// pours down the face. What sells it as moving water is the flow: long
// streaks drawn out the way the water runs, slow broad ones and fast thin
// ones, wavering a little side to side, with glints sliding along them.
// Thick water is deep blue; where it thins over the crest and in the curl
// the light comes through it, paler and greener.
// Frozen (ice > 0, Frozen Wall of Water) the same wave turns to ice from
// the feet up: where the ice reaches the water stops, its threads set
// as pale veins in clear blue ice under patches of white rime, a bright
// band riding the freezing edge.

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D ripples : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec3 deep_color : source_color = vec3(0.03, 0.17, 0.32);
uniform vec3 mid_color : source_color = vec3(0.06, 0.38, 0.55);
uniform vec3 thin_color : source_color = vec3(0.3, 0.75, 0.78);
uniform vec3 streak_color : source_color = vec3(0.75, 0.92, 0.97);
// How far the flow's ridges tilt the surface.
uniform float chop = 0.06;
// How far it bends what's behind, as a fraction of the screen.
uniform float refraction = 0.02;
// How far the flowing bulges stand out, metres.
uniform float churn = 0.06;
uniform vec3 ice_deep : source_color = vec3(0.32, 0.55, 0.68);
uniform vec3 ice_pale : source_color = vec3(0.7, 0.87, 0.93);
uniform vec3 rime_color : source_color = vec3(0.93, 0.97, 1.0);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	SETTLE_VERTEX
	// Bulges riding down the flow, none at the feet, which sit on the
	// ground.
	float feet = smoothstep(0.0, 0.08, share) * smoothstep(1.0, 0.9, share);
	float bulge = textureLod(streaks, vec2(UV.x * 0.25, UV.y * 0.15 - clock(iced_at(CUSTOM1.z)) * flow_speed * 0.15), 0.0).r - 0.5;
	VERTEX += NORMAL * bulge * churn * feet * height;
}

// Threads of water running with the flow: one every `across` metres
// across the wall, wavering side to side, broken into dashes `along` metres
// apart, each column running at its own pace around `speed` times the flow.
float threads(vec2 uv, float across, float along, float speed, float seed, float now) {
	float wob = texture(streaks, vec2(uv.x * 0.1 + seed, uv.y * 0.05 - now * 0.02)).r - 0.5;
	float c = uv.x / across + wob * 1.5;
	float id = floor(c);
	float f = fract(c) - 0.5;
	float w = mix(0.1, 0.25, hash(vec2(id, seed)));
	float line = smoothstep(w, w * 0.3, abs(f));
	float pace = speed * (0.7 + 0.6 * hash(vec2(id, seed + 3.1)));
	float y = (uv.y - now * flow_speed * pace) / along + hash(vec2(id, seed + 7.7)) * 10.0;
	float yid = floor(y);
	float yf = fract(y);
	float on = step(0.15, hash(vec2(id * 13.1 + yid, seed)));
	float len = 0.4 + 0.5 * hash(vec2(yid, id + seed));
	float dash = smoothstep(0.0, 0.15, yf) * smoothstep(len, len - 0.2, yf);
	return line * dash * on;
}

void fragment() {
	float iced = iced_at(rise);
	float now = clock(iced);
	float t = now * flow_speed;
	// Ridges drawn out the way the water runs, scrolling with it.
	vec3 n1 = texture(ripples, vec2(UV.x * 0.3, UV.y * 0.02 - t * 0.02)).rgb * 2.0 - 1.0;
	vec3 n2 = texture(ripples, vec2(UV.x * 0.7 + 0.3, UV.y * 0.04 - t * 0.04)).rgb * 2.0 - 1.0;
	vec2 tilt = (n1.xy + n2.xy * 0.5) * chop;
	NORMAL = normalize(NORMAL + TANGENT * tilt.x * 0.4 + BINORMAL * tilt.y);

	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fresnel = pow(1.0 - facing, 4.0);
	float thin = 1.0 - smoothstep(0.1, 1.0, thickness);

	// Broad slow ribbons and thin fast threads, both running with the water.
	float broad = threads(UV, 0.45, 4.0, 1.4, 0.0, now);
	float fine = threads(UV + vec2(0.31, 0.0), 0.2, 2.5, 2.0, 0.37, now);
	float hair = threads(UV + vec2(0.13, 0.0), 0.12, 1.8, 2.6, 0.71, now);
	float lines = clamp(broad * 0.6 + fine * 0.5 + hair * 0.35, 0.0, 1.0);

	vec3 water = mix(deep_color, mid_color, smoothstep(0.0, 0.6, rise));
	water = mix(water, thin_color, thin * 0.6);
	water = mix(water, streak_color, lines * mix(0.5, 0.75, thin));
	vec2 bend = tilt * refraction;
	vec3 behind = textureLod(screen_texture, SCREEN_UV + bend, 0.0).rgb;

	// Ice: clear blue, paler where thin, the set threads pale veins,
	// white rime in patches and along the thin lip.
	float rime = texture(streaks, UV * vec2(0.35, 0.5) + vec2(0.17, 0.4)).r;
	rime = smoothstep(0.5, 0.7, rime + thin * 0.2);
	vec3 frozen = mix(ice_deep, ice_pale, clamp(thin * 0.7 + rise * 0.25, 0.0, 1.0));
	frozen = mix(frozen, rime_color, max(lines * 0.45, rime * 0.75));
	// The freezing edge, bright as it passes.
	float edge = iced * (1.0 - iced) * 4.0;

	ALBEDO = mix(water * 0.25, frozen * 0.75, iced);
	ROUGHNESS = mix(0.18, mix(0.08, 0.6, rime), iced);
	SPECULAR = mix(0.12, 0.35, iced);
	BACKLIGHT = mix(thin_color * thin * 0.6, ice_pale * thin * 0.4, iced);
	EMISSION = mix(water * 0.2 + behind * thin * 0.15 + vec3(0.45, 0.65, 0.8) * fresnel * 0.12,
			frozen * 0.06 + behind * thin * 0.08 + rime_color * fresnel * 0.1, iced) + rime_color * edge * 0.5;
	// Fades into the ground at both feet, so there's no seam.
	float alpha = mix(mix(0.93, 0.98, lines), 0.97, iced) * smoothstep(0.0, 0.03, share) * smoothstep(1.0, 0.86, share);

	ALPHA = alpha * strength * smoothstep(0.0, 0.15, height);
}
