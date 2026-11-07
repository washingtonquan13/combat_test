shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_schlick_ggx;
#include "res://systems/surface_system/water_wall.gdshaderinc"

// The foam the Wall of Water churns up on the ground (water_wall.gd):
// a band where the curtain lands in front of it, rolling out away from
// it and breaking up as it goes, and a thinner one where the water is
// drawn in at its back foot. UV.x is metres along the wall, UV.y metres
// out from the wave; CUSTOM1.x 0 at the wave, 1 at the band's far edge.

uniform vec3 foam_color : source_color = vec3(0.86, 0.94, 0.96);
uniform vec3 water_color : source_color = vec3(0.1, 0.4, 0.46);
uniform sampler2D foam_cells : filter_linear_mipmap, repeat_enable;
// Metres a second it rolls out.
uniform float roll_speed = 0.6;

void vertex() {
	SETTLE_VERTEX
}

void fragment() {
	NORMAL = normalize((VIEW_MATRIX * vec4(up_local, 0.0)).xyz);
	float roll = TIME * roll_speed;
	float cells = texture(foam_cells, vec2(UV.x * 0.7, UV.y * 0.7 - roll * 0.7)).r;
	float big = texture(streaks, vec2(UV.x * 0.25, UV.y * 0.3 - roll * 0.3)).r;
	// Dense where it lands, thinning out into lace toward the edge.
	float cover = mix(1.0, 0.05, smoothstep(0.0, 1.0, share)) * (0.6 + 0.8 * big);
	float foam = smoothstep(1.0 - cover, 1.0 - cover + 0.2, cells);
	ALBEDO = mix(water_color, foam_color, foam);
	ROUGHNESS = mix(0.15, 0.85, foam);
	SPECULAR = 0.4;
	EMISSION = foam_color * foam * 0.2;
	float alpha = mix(0.1, 0.75, foam) * smoothstep(1.0, 0.7, share) * smoothstep(0.0, 0.05, share);
	ALPHA = alpha * strength * smoothstep(0.0, 0.3, height);
}
