shader_type spatial;

// Four ground layers painted by vertex colour: R rock, G soil, B grass, A dirt.
// UV carries the water: x the riverbed's stones, y how damp the bank is.
//
// Each layer's ARM texture carries its height in B (metallic is unused;
// tools/quarry/height_from_normal.py writes it). Layers meet by height: where
// two are painted half and half, the higher texel wins, so soil settles into
// the gaps between the dirt's stones and the stones keep their edges.
//
// The flat layers are read at two random offsets chosen by a slow noise and
// blended where the noise moves from one to the next, so the 3 m tiles stop
// lining up into a grid when seen from the rim.

uniform sampler2D rock_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_arm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D soil_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D soil_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D soil_arm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D grass_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D grass_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D grass_arm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dirt_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dirt_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dirt_arm : filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D bed_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D bed_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D bed_arm : filter_linear_mipmap_anisotropic, repeat_enable;

// Seamless grey noise, read at several scales. Drives tile offsets and the
// colour drift across the valley.
uniform sampler2D variation : filter_linear_mipmap, repeat_enable;

uniform float rock_tile = 0.22;
uniform float bed_tile = 0.45;
uniform float soil_tile = 0.30;
uniform float grass_tile = 0.33;
uniform float dirt_tile = 0.36;
// How far a layer's relief reaches into its neighbour, in height units.
uniform float blend_depth = 0.18;

varying vec3 world_pos;
varying vec3 tri_weights;
varying vec2 wet;

vec4 triplanar(sampler2D tex, vec3 pos) {
	vec4 s = texture(tex, pos.xy) * tri_weights.z;
	s += texture(tex, pos.xz) * tri_weights.y;
	s += texture(tex, pos.zy * vec2(-1.0, 1.0)) * tri_weights.x;
	return s;
}

vec2 hash2(float n) {
	return fract(sin(vec2(n * 127.1 + 1.7, n * 311.7 + 9.3)) * 43758.5453);
}

// One read of a flat layer, untiled. The derivatives are taken once outside
// the branch, so a pixel that reads only one offset still gets the same mip
// as its neighbours that read both: no sparkle where the blend starts.
vec4 untiled(sampler2D tex, vec2 uv, vec2 o1, vec2 o2, float b) {
	vec2 dx = dFdx(uv);
	vec2 dy = dFdy(uv);
	if (b < 0.01) {
		return textureGrad(tex, uv + o1, dx, dy);
	}
	if (b > 0.99) {
		return textureGrad(tex, uv + o2, dx, dy);
	}
	return mix(textureGrad(tex, uv + o1, dx, dy), textureGrad(tex, uv + o2, dx, dy), b);
}

void vertex() {
	world_pos = VERTEX * vec3(1.0, -1.0, 1.0);
	wet = UV;
	vec3 n = abs(NORMAL);
	tri_weights = pow(n, vec3(6.0));
	tri_weights /= dot(tri_weights, vec3(1.0));
	TANGENT = normalize(vec3(0.0, 0.0, -1.0) * n.x + vec3(1.0, 0.0, 0.0) * n.y + vec3(1.0, 0.0, 0.0) * n.z);
	BINORMAL = normalize(vec3(0.0, 1.0, 0.0) * n.x + vec3(0.0, 0.0, -1.0) * n.y + vec3(0.0, 1.0, 0.0) * n.z);
}

float lum(vec3 c) {
	return dot(c, vec3(0.33));
}

// Unpacks a normal map texel, adds `detail` to it (whiteout blend), packs it back.
vec3 add_normal(vec3 base, vec3 detail, float amount) {
	vec3 a = base * 2.0 - 1.0;
	vec3 b = detail * 2.0 - 1.0;
	vec3 n = normalize(vec3(a.xy + b.xy * amount, a.z));
	return n * 0.5 + 0.5;
}

void fragment() {
	vec2 xz = world_pos.xz;
	vec4 var_slow = texture(variation, xz * 0.012);
	vec4 var_fast = texture(variation, xz * 0.05);
	// The same noise turned and shifted, so light patches don't trace the
	// tile offsets' seams.
	vec4 var_tone = texture(variation, mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * xz * 0.037 + 0.41);

	// Tile offsets: eight random placements, the slow noise walking between them.
	float k = var_fast.r * 8.0;
	float i = floor(k);
	vec2 o1 = hash2(i);
	vec2 o2 = hash2(i + 1.0);
	float ob = smoothstep(0.3, 0.7, fract(k));

	vec2 uv_s = xz * soil_tile;
	vec2 uv_g = xz * grass_tile;
	vec2 uv_d = xz * dirt_tile;
	vec3 rock_pos = world_pos * rock_tile;

	vec3 r_a = triplanar(rock_albedo, rock_pos).rgb;
	vec3 s_a = untiled(soil_albedo, uv_s, o1, o2, ob).rgb;
	vec3 g_a = texture(grass_albedo, uv_g).rgb;
	vec3 d_a = untiled(dirt_albedo, uv_d, o1, o2, ob).rgb;
	vec3 r_m = triplanar(rock_arm, rock_pos).rgb;
	vec3 s_m = untiled(soil_arm, uv_s, o1, o2, ob).rgb;
	vec3 g_m = texture(grass_arm, uv_g).rgb;
	vec3 d_m = untiled(dirt_arm, uv_d, o1, o2, ob).rgb;
	vec3 r_n = triplanar(rock_normal, rock_pos).rgb;
	vec3 s_n = untiled(soil_normal, uv_s, o1, o2, ob).rgb;
	vec3 g_n = mix(texture(grass_normal, uv_g).rgb, vec3(0.5, 0.5, 1.0), 0.6);
	vec3 d_n = untiled(dirt_normal, uv_d, o1, o2, ob).rgb;

	// Forest floor, not dry field: the grass layer pulled green and dark,
	// the soil to a damp loam. Under the grass cards the ground is the shade
	// at the roots of the blades, so the texture's gravel is evened out
	// toward its average and darkened: gaps between clumps read as deeper
	// grass, not bare stones.
	g_a = mix(textureLod(grass_albedo, uv_g, 7.0).rgb, g_a, 0.3);
	g_a = mix(vec3(lum(g_a)), g_a, 1.3) * vec3(0.3, 0.5, 0.22);
	r_a = mix(vec3(lum(r_a)), r_a, 0.75);
	s_a = s_a * vec3(0.72, 0.68, 0.6);
	d_a = mix(vec3(lum(d_a)), d_a, 0.3) * vec3(0.74, 0.72, 0.66);

	// Height blend. Paint decides how high a layer is lifted, its texture
	// decides where inside the blend it shows. The grass layer is flattened:
	// its cards stand on it, its own relief would only show as gravel.
	vec4 h = vec4(r_m.b, s_m.b, g_m.b * 0.4 + 0.3, d_m.b) * 0.5;
	vec4 lift = COLOR + h;
	float top = max(max(lift.r, lift.g), max(lift.b, lift.a)) - blend_depth;
	vec4 w = max(lift - vec4(top), vec4(0.0));
	w /= max(w.r + w.g + w.b + w.a, 0.0001);
	float height = dot(h, w) * 2.0;

	// Colour drift across the valley: warm and cool patches at tens of
	// metres, light and dark at a few. Rock keeps most of its own colour.
	vec3 drift = mix(vec3(0.93, 0.97, 1.05), vec3(1.07, 1.0, 0.9), smoothstep(0.25, 0.75, var_slow.r));
	drift *= mix(0.86, 1.12, smoothstep(0.2, 0.8, var_tone.r));
	vec3 dry = r_a * w.r + s_a * w.g + g_a * w.b + d_a * w.a;
	dry *= mix(drift, vec3(1.0), w.r * 0.75);

	vec2 uv_b = xz * bed_tile;
	vec3 b_a = texture(bed_albedo, uv_b).rgb;
	vec3 b_m = texture(bed_arm, uv_b).rgb;
	vec3 b_n = texture(bed_normal, uv_b).rgb;
	// The riverbed's stones stand out of the bank first, the gaps last.
	float bed = clamp(wet.x * (0.3 + b_m.b * 1.8) - 0.2, 0.0, 1.0);
	bed = smoothstep(0.1, 0.7, bed);
	height = mix(height, b_m.b, bed);
	// Damp ground darkens most in its hollows, where water would sit.
	float damp = wet.y * mix(1.15, 0.7, height);
	ALBEDO = mix(dry, b_a * 0.8, bed) * mix(1.0, 0.62, clamp(damp, 0.0, 1.0));

	vec3 arm = r_m * w.r + s_m * w.g + g_m * w.b + d_m * w.a;
	vec3 nrm = r_n * w.r + s_n * w.g + g_n * w.b + d_n * w.a;
	arm = mix(arm, b_m, bed);
	nrm = mix(nrm, b_n, bed);

	// Far away the normal map's mips have flattened its relief; a read of
	// the dirt at a fifth of its scale puts bumps back at the size a pixel
	// still sees.
	float dist = length(VERTEX);
	float far = smoothstep(14.0, 50.0, dist) * (1.0 - w.r) * (1.0 - bed);
	vec3 far_n = texture(dirt_normal, xz * dirt_tile * 0.21 + o1).rgb;
	nrm = add_normal(nrm, far_n, far * 0.8);

	// Crevices: the rock's own height deepens its AO.
	AO = arm.r * mix(1.0, mix(0.55, 1.0, r_m.b), w.r);
	AO_LIGHT_AFFECT = 0.4;
	ROUGHNESS = mix(clamp(arm.g, 0.55, 1.0), 0.35, clamp(damp, 0.0, 1.0) * 0.8);
	METALLIC = 0.0;
	NORMAL_MAP = nrm;
	NORMAL_MAP_DEPTH = 1.1;
}
