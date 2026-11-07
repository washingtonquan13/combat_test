shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_schlick_ggx;
#include "res://systems/surface_system/water_wall.gdshaderinc"

// The curtain the Wall of Water's lip throws down in front of its face
// (water_wall.gd): water falling, torn into strands that thin out toward
// the ground and whiten as it goes, landing in the foam. UV.x is metres
// along the wall, UV.y metres down the curtain from the lip; CUSTOM1.x
// 0 at the lip, 1 at the ground.

uniform vec3 water_color : source_color = vec3(0.12, 0.55, 0.6);
uniform vec3 foam_color : source_color = vec3(0.86, 0.94, 0.96);
uniform sampler2D foam_cells : filter_linear_mipmap, repeat_enable;
uniform float crackle = 0.0;
uniform vec3 crackle_color : source_color = vec3(0.45, 0.7, 1.0);
uniform float crackle_energy = 6.0;

void vertex() {
	SETTLE_VERTEX
	// It sways forward and back as it falls.
	float sway = textureLod(streaks, vec2(UV.x * 0.4, UV.y * 0.3 - TIME * flow_speed * 0.3), 0.0).r - 0.5;
	VERTEX += NORMAL * sway * 0.25 * share * height;
}

void fragment() {
	float fall = TIME * flow_speed * 1.3;
	float strands = texture(streaks, vec2(UV.x * 1.1, UV.y * 0.45 - fall * 0.45)).r;
	float fine = texture(streaks, vec2(UV.x * 4.0 + 0.3, UV.y * 0.6 - fall * 0.6)).r;
	float torn = strands * 0.7 + fine * 0.3;
	// Whole near the lip, strands lower down, few by the ground.
	float keep = mix(0.42, 0.68, share);
	float body = smoothstep(keep, keep + 0.1, torn);
	float cells = texture(foam_cells, vec2(UV.x * 0.8, UV.y * 0.6 - fall * 0.6)).r;
	float foam = clamp(smoothstep(0.6 - share * 0.5, 0.9 - share * 0.4, cells) + share * 0.4, 0.0, 1.0);
	ALBEDO = mix(water_color * 0.6, foam_color, foam);
	ROUGHNESS = mix(0.1, 0.8, foam);
	SPECULAR = 0.5;
	BACKLIGHT = water_color * (1.0 - foam);
	EMISSION = water_color * 0.25 * (1.0 - foam) + foam_color * foam * 0.3;
	float alpha = body * mix(0.35, 0.85, foam);
	if (crackle > 0.0) {
		float line = smoothstep(0.03, 0.0, abs(fine - 0.5)) * smoothstep(0.6, 0.8, strands);
		EMISSION += crackle_color * crackle_energy * line * crackle * 0.6;
	}
	// Fades in from under the lip, so there's no seam.
	alpha *= smoothstep(0.0, 0.08, share);
	ALPHA = alpha * strength * smoothstep(0.0, 0.2, height);
}
