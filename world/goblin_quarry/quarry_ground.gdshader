shader_type spatial;

// Four ground layers painted by vertex colour: R rock, G soil, B grass, A dirt.
// UV carries the water: x the riverbed's stones, y how damp the bank is.
// The layers meet along the bright parts of their own textures, so the edge
// between soil and dirt follows pebbles instead of a smooth fade.

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

uniform float rock_tile = 0.22;
uniform float bed_tile = 0.45;
uniform float soil_tile = 0.30;
uniform float grass_tile = 0.33;
uniform float dirt_tile = 0.36;

varying vec3 world_pos;
varying vec3 tri_weights;
varying vec2 wet;

vec4 triplanar(sampler2D tex, vec3 pos) {
	vec4 s = texture(tex, pos.xy) * tri_weights.z;
	s += texture(tex, pos.xz) * tri_weights.y;
	s += texture(tex, pos.zy * vec2(-1.0, 1.0)) * tri_weights.x;
	return s;
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

void fragment() {
	vec3 rock_pos = world_pos * rock_tile;
	vec3 r_a = triplanar(rock_albedo, rock_pos).rgb;
	r_a = mix(vec3(lum(r_a)), r_a, 0.75);
	vec2 uv_s = world_pos.xz * soil_tile;
	vec2 uv_g = world_pos.xz * grass_tile;
	vec2 uv_d = world_pos.xz * dirt_tile;
	vec3 s_a = texture(soil_albedo, uv_s).rgb;
	vec3 g_a = texture(grass_albedo, uv_g).rgb;
	vec3 d_a = texture(dirt_albedo, uv_d).rgb;
	// Forest floor, not dry field: the grass layer pulled green and dark,
	// the soil to a damp loam.
	g_a = mix(vec3(lum(g_a)), g_a, 1.2) * vec3(0.5, 0.68, 0.36);
	s_a = s_a * vec3(0.72, 0.68, 0.6);
	d_a = mix(vec3(lum(d_a)), d_a, 0.3) * vec3(0.74, 0.72, 0.66);

	vec4 w = COLOR * (vec4(0.35) + vec4(lum(r_a), lum(s_a), lum(g_a), lum(d_a)) * 1.6);
	w = pow(w, vec4(3.0));
	w /= max(w.r + w.g + w.b + w.a, 0.0001);

	// Large soft patches, so the same tile doesn't read as a repeat from far away.
	float macro = texture(soil_albedo, world_pos.xz * 0.031).g;
	macro = mix(0.86, 1.14, smoothstep(0.08, 0.34, macro));

	vec3 dry = (r_a * w.r + s_a * w.g + g_a * w.b + d_a * w.a) * mix(macro, 1.0, w.r * 0.8);
	vec2 uv_b = world_pos.xz * bed_tile;
	vec3 b_a = texture(bed_albedo, uv_b).rgb;
	float bed = clamp(wet.x * (0.4 + lum(b_a) * 1.6) - 0.2, 0.0, 1.0);
	bed = smoothstep(0.1, 0.7, bed);
	ALBEDO = mix(dry, b_a * 0.8, bed) * mix(1.0, 0.62, wet.y);

	// Sampled outside any branch: a texture read inside a per-pixel if has no
	// valid mip level where neighbouring pixels branch differently, and those
	// pixels sparkle as the camera moves.
	vec3 arm = triplanar(rock_arm, rock_pos).rgb * w.r
		+ texture(soil_arm, uv_s).rgb * w.g
		+ texture(grass_arm, uv_g).rgb * w.b
		+ texture(dirt_arm, uv_d).rgb * w.a;
	vec3 nrm = triplanar(rock_normal, rock_pos).rgb * w.r
		+ texture(soil_normal, uv_s).rgb * w.g
		+ texture(grass_normal, uv_g).rgb * w.b
		+ texture(dirt_normal, uv_d).rgb * w.a;
	arm = mix(arm, texture(bed_arm, uv_b).rgb, bed);
	nrm = mix(nrm, texture(bed_normal, uv_b).rgb, bed);
	AO = arm.r;
	AO_LIGHT_AFFECT = 0.4;
	ROUGHNESS = mix(clamp(arm.g, 0.55, 1.0), 0.35, wet.y * 0.8);
	METALLIC = 0.0;
	NORMAL_MAP = nrm;
	NORMAL_MAP_DEPTH = 1.1;
}
