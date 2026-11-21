// Value noise computed in the shader, shared by the wind (wind.gdshaderinc)
// and the valley's colour drift (grass_colour.gdshaderinc). Computed, not a
// texture: a texture would be one more parameter every baked material has to
// carry, which means a rebake.

#ifndef VALUE_NOISE_GDSHADERINC
#define VALUE_NOISE_GDSHADERINC

// A hash without sin (D. Hoskins, "Hash without Sine"): cheaper per vertex.
float value_hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// Value noise, 0..1, one feature per unit.
float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(value_hash(i), value_hash(i + vec2(1.0, 0.0)), f.x), mix(value_hash(i + vec2(0.0, 1.0)), value_hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

#endif
