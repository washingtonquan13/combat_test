// The city overworld's buildings: a concrete palette that drifts across
// districts, a little variation per building, window rows keyed to world
// height so every storey lines up across the city, and darker roofs.
// UV2 is (kind, tint) from osm_city.py: kind 0 wall, 1 roof.
shader_type spatial;
render_mode cull_back;

uniform vec3 district_a : source_color = vec3(0.86, 0.83, 0.77);
uniform vec3 district_b : source_color = vec3(0.74, 0.76, 0.78);
uniform vec3 district_c : source_color = vec3(0.84, 0.78, 0.68);
// World units across one patch of the district palette.
uniform float district_size = 260.0;
uniform float tint_strength = 0.08;
uniform vec3 roof_color : source_color = vec3(0.40, 0.41, 0.44);
uniform float roof_mix = 0.8;
uniform vec3 window_color : source_color = vec3(0.22, 0.26, 0.32);
// One storey and one window bay, in world units after scaling.
uniform float storey = 1.02;
uniform float bay = 0.9;
uniform vec2 window_size = vec2(0.55, 0.45);
// Storeys below this height are shopfronts and get no window rows.
uniform float plinth = 0.6;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

// 1 inside a window cell, 0 outside, smoothed over one pixel and fading
// to the average once a cell is smaller than a couple of pixels.
float cells(float t, float fill) {
	float w = fwidth(t);
	float edge = 0.5 * fill;
	float d = abs(fract(t) - 0.5);
	float hard = 1.0 - smoothstep(edge - w, edge + w, d);
	return mix(hard, fill, smoothstep(0.25, 0.6, w));
}

void fragment() {
	vec2 xz = world_pos.xz / district_size;
	float n1 = noise(xz);
	float n2 = noise(xz * 2.3 + 17.0);
	vec3 base = mix(mix(district_a, district_b, smoothstep(0.35, 0.65, n1)), district_c, smoothstep(0.55, 0.8, n2));
	float tint = UV2.y - 0.5;
	base *= 1.0 + tint * 2.0 * tint_strength;
	base = mix(base, base.gbr, abs(tint) * tint_strength);

	vec3 col = base;
	if (UV2.x > 0.5) {
		col = mix(base, roof_color, roof_mix);
	} else if (world_pos.y > plinth) {
		vec2 side = normalize(vec2(-world_normal.z, world_normal.x));
		float along = dot(world_pos.xz, side) / bay;
		float up = (world_pos.y - plinth) / storey;
		float win = cells(along, window_size.x) * cells(up - 0.1, window_size.y);
		col = mix(base, window_color, win * 0.75);
		ROUGHNESS = mix(0.9, 0.35, win);
		SPECULAR = mix(0.3, 0.6, win);
	}
	ALBEDO = col;
	if (UV2.x > 0.5) {
		ROUGHNESS = 0.95;
	}
}
