shader_type spatial;
render_mode diffuse_lambert_wrap;

// Bark of generated trees. COLOR.r is baked occlusion, COLOR.a height up the
// tree; see tools/quarry/plant_gen.gd.

#include "res://world/goblin_quarry/tree_wind.gdshaderinc"

uniform sampler2D albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 tint = vec3(0.85, 0.82, 0.8);

void vertex() {
	VERTEX = tree_wind(VERTEX, UV2, COLOR.a, MODEL_MATRIX[3].xyz, TIME);
}

void fragment() {
	ALBEDO = texture(albedo, UV).rgb * tint * COLOR.r;
	NORMAL_MAP = texture(normal_map, UV).rgb;
	ROUGHNESS = 0.9;
	SPECULAR = 0.3;
}
