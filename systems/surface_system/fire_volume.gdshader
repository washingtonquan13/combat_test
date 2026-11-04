shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_front, depth_test_disabled, shadows_disabled;

// Wall of Fire's flame as one live volume (fire_wall.gd): tiling noise
// rising through a box round the wall's cubes, looked through by marching
// each pixel's ray across it. Big slow noise bends the rising noise so
// tongues lick and merge; the fire needs more of it to burn the higher it
// goes, so it thins into tongues at the top. It burns only over the cubes'
// columns (`columns`), so it takes the grid's shape and dies out where
// they recede. Nothing is baked and nothing repeats.

uniform sampler3D noise : filter_linear, repeat_enable;
// One texel per CloudGrid column round the wall: r how much it burns (0..1),
// g and b its foot and top, in the wall's space, a how hot it flashes as
// it catches (fire_ignition.gd). Read soft for r, so the
// fuel spreads a little past the cubes and their corners round off.
uniform sampler2D columns_soft : filter_linear, repeat_disable;
uniform sampler2D columns : filter_nearest, repeat_disable;
// The columns texture's corner in the wall's xz, and its size in cubes.
uniform vec2 columns_origin;
uniform vec2 columns_count = vec2(1.0);
uniform vec3 box_size = vec3(8.0, 4.4, 1.2);
// The box's centre in the wall's space, and in the world (the noise is
// world-fixed, so no two walls burn alike).
uniform vec3 box_offset;
uniform vec3 world_offset;
// Meters a second the flame rises.
uniform float rise = 2.2;
// Noise tiles per meter for the tongues and the detail: across, up.
uniform vec2 tongue_scale = vec2(0.3, 0.14);
uniform vec2 detail_scale = vec2(0.75, 0.4);
uniform float detail = 0.35;
// Meters the big slow noise bends the tongues by.
uniform float warp = 1.4;
// How much noise the flame needs to burn at its foot and its top.
uniform float foot_threshold = 0.22;
uniform float top_threshold = 0.74;
uniform float contrast = 4.0;
// How much fuel the flame needs at its foot and its top: low is thick.
uniform float foot_fuel = 0.12;
uniform float top_fuel = 0.6;
// How much a catching flame's flash adds to its heat (and, flash_color,
// turns it toward the core colour).
uniform float flash_heat = 0.8;
// The whole wall's burn, faded out as it dissipates.
uniform float strength = 1.0;

float sample_noise(vec3 p) {
	return texture(noise, p).r;
}

float flame(vec3 p, float t, out float flash) {
	vec3 w = p + world_offset;
	vec3 slow = w * 0.12 - vec3(0.0, t * rise * 0.07, 0.0);
	vec3 bend = vec3(sample_noise(slow), sample_noise(slow + vec3(0.31, 0.17, 0.53)),
			sample_noise(slow + vec3(0.71, 0.43, 0.11))) - 0.5;
	vec3 local = p + box_offset;
	vec2 uv = (local.xz + bend.xz * 0.6 - columns_origin) / columns_count;
	vec4 soft = texture(columns_soft, uv);
	float fuel = soft.r;
	flash = soft.a;
	if (fuel < foot_fuel) {
		return 0.0;
	}
	vec2 span = texture(columns, uv).gb;
	float y = (local.y - span.x) / max(span.y - span.x, 0.05);
	if (y < 0.0 || y > 1.0) {
		return 0.0;
	}
	w += bend * warp * (0.3 + y);
	vec3 up = vec3(0.0, t * rise, 0.0);
	float n = sample_noise((w - up) * tongue_scale.xyx);
	n = mix(n, sample_noise((w - up * 1.6) * detail_scale.xyx + 0.37), detail);
	float lo = mix(foot_fuel, top_fuel, y);
	float body = smoothstep(lo, lo + 0.3, fuel);
	float heat = clamp((n - mix(foot_threshold, top_threshold, y)) * contrast * body, 0.0, 1.0);
	heat = min(heat * (1.0 + flash * flash_heat), 1.0);
	// Die out before the top, so no tongue is cut flat.
	return heat * (1.0 - smoothstep(0.7, 0.97, y));
}

float fire_heat(vec3 p, out float flash) {
	return flame(p, TIME, flash) * strength;
}

#include "res://systems/surface_system/fire_march.gdshaderinc"

void fragment() {
	vec4 fire = march_fire(box_size, SCREEN_UV, FRAGCOORD.xy, MODEL_MATRIX, INV_VIEW_MATRIX, INV_PROJECTION_MATRIX);
	if (fire.a <= 0.0) {
		discard;
	}
	ALBEDO = fire.rgb;
	ALPHA = fire.a;
}
