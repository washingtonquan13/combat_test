// The fog wall at the edge of the city overworld, shared by every city
// material: past the boundary there is no more map. A surface turns to the
// haze over the last edge_fade metres inside the line and is nothing but
// haze from the line out, the colour the environment's background shows,
// so a deck running on past the edge, or the view past the city when the
// camera stands beyond it, reads as fog and never as the end of a model.
//
// edge_tex holds the signed distance to the boundary in metres, inside
// positive, baked by tools/blockout/shore_field.py.
uniform sampler2D edge_tex : filter_linear, repeat_disable;
// Where edge_tex lies, in world units.
uniform vec2 edge_origin = vec2(0.0);
uniform vec2 edge_size = vec2(1.0);
uniform float edge_fade = 80.0;
uniform vec3 edge_fog_color : source_color = vec3(0.72, 0.76, 0.80);
uniform bool has_edge = false;

// Signed metres from a world position to the boundary, inside positive.
// Off the baked field is far outside the city.
float edge_metres(vec2 xz) {
	vec2 uv = (xz - edge_origin) / edge_size;
	float metres = textureLod(edge_tex, clamp(uv, vec2(0.0), vec2(1.0)), 0.0).r;
	bool off = any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)));
	return off ? -1e4 : metres;
}

// How far a surface at a world position has turned to fog, 0 to 1. The
// caller scales ALBEDO and SPECULAR by 1 - fog and mixes EMISSION toward
// edge_fog_color by fog, so a fully fogged surface shows the fog colour
// alone, unlit and unshadowed.
float edge_fog(vec3 world) {
	if (!has_edge) {
		return 0.0;
	}
	return 1.0 - smoothstep(0.0, edge_fade, edge_metres(world.xz));
}
