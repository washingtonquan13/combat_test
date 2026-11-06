// The city overworld's ground, in the vertex colours osm_city.py gives
// each ground class, under the fog at the map's edge,
// city_edge_fog.gdshaderinc. Otherwise what a StandardMaterial3D with
// sRGB vertex colours as albedo draws.
shader_type spatial;
render_mode cull_back;
#include "res://world/city_edge_fog.gdshaderinc"

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// The builder's vertex colours are sRGB.
	vec3 c = COLOR.rgb;
	ALBEDO = mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), lessThan(c, vec3(0.04045)));
	ROUGHNESS = 1.0;
	float fog = edge_fog(world_pos);
	ALBEDO *= 1.0 - fog;
	SPECULAR *= 1.0 - fog;
	EMISSION = edge_fog_color * fog;
}
