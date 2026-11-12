shader_type spatial;
// The spider cave's rock: one mesh for floor, walls and roof, textured
// triplanar in world space since a surface-nets mesh has no UVs. Faces that
// look up get a floor of packed dirt and loose stones, with stones settling
// into the low spots; everything else is the quarry's rock face, darker and
// damp. COLOR.r is how open the air is just off the surface (from the
// generator), darkening crevices and the angle where wall meets floor.
//
// The generator also hands over the rock's shape, which the paint follows:
// COLOR.g hollow (above 0.5) or crest (below) against the rock a stride
// away, COLOR.b how much seeping water runs down through here, COLOR.a how
// open the air is several metres out. Hollows are darker and damper, crests
// paler and drier, water leaves dark glossy streaks down the walls and damp
// patches where it gathers on the floor, and alcoves fall into shade.
//
// The mesh has no tangents, so the textures' normals are applied in world
// space, each projection bending the surface along its own axes. A second,
// much larger copy of the rock's normals gives the walls folds a metre or
// two across that the 0.4 m mesh cannot carry.

uniform sampler2D rock_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_arm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D floor_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D floor_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D floor_arm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D stones_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D stones_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D stones_arm : filter_linear_mipmap_anisotropic, repeat_enable;

uniform float rock_tile = 0.2;
uniform float floor_tile = 0.33;
uniform float stones_tile = 0.5;
uniform vec3 rock_tint : source_color = vec3(0.62, 0.6, 0.6);
uniform vec3 floor_tint : source_color = vec3(0.5, 0.5, 0.5);
uniform float wet_roughness = 0.55;
uniform float ao_strength = 0.85;
uniform float relief = 1.2;          // the textures' own bumps
uniform float macro_scale = 0.22;    // the large copy's tiling, times rock_tile
uniform float macro_relief = 1.6;
uniform float shape_paint = 1.0;     // 0 ignores COLOR.gba
uniform float streak_gloss = 0.6;    // how much glossier running water is

varying vec3 world_pos;
varying vec3 world_nrm;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_nrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

vec4 tri(sampler2D tex, vec3 p, vec3 w) {
	return texture(tex, p.zy * vec2(-1.0, 1.0)) * w.x
		+ texture(tex, p.xz) * w.y
		+ texture(tex, p.xy) * w.z;
}

// The bend a normal map gives the surface, in world space. Red leans along
// +U; green leans up the image, which is -V.
vec3 tri_bend(sampler2D tex, vec3 p, vec3 w) {
	vec2 x = texture(tex, p.zy * vec2(-1.0, 1.0)).xy * 2.0 - 1.0;
	vec2 y = texture(tex, p.xz).xy * 2.0 - 1.0;
	vec2 z = texture(tex, p.xy).xy * 2.0 - 1.0;
	return vec3(0.0, -x.y, -x.x) * w.x + vec3(y.x, 0.0, -y.y) * w.y + vec3(z.x, -z.y, 0.0) * w.z;
}

void fragment() {
	vec3 w = pow(abs(world_nrm), vec3(4.0));
	w /= w.x + w.y + w.z;
	vec3 pr = world_pos * rock_tile;
	vec3 r_a = tri(rock_albedo, pr, w).rgb * rock_tint;
	vec3 r_bend = tri_bend(rock_normal, pr, w);
	vec3 macro = tri_bend(rock_normal, pr * macro_scale, w) * macro_relief;
	vec3 r_arm = tri(rock_arm, pr, w).rgb;

	vec2 uf = world_pos.xz * floor_tile;
	vec2 us = world_pos.xz * stones_tile;
	vec3 f_a = texture(floor_albedo, uf).rgb * floor_tint;
	vec2 f_n = texture(floor_normal, uf).xy;
	vec3 f_arm = texture(floor_arm, uf).rgb;
	vec3 s_a = texture(stones_albedo, us).rgb * floor_tint;
	vec2 s_n = texture(stones_normal, us).xy;
	vec3 s_arm = texture(stones_arm, us).rgb;
	// Stones gather in patches and against the walls (where the air closes in).
	float patch = texture(floor_albedo, world_pos.xz * 0.04).g;
	float shape = (COLOR.g - 0.5) * 2.0 * shape_paint;
	float run = COLOR.b * shape_paint;
	float stones = smoothstep(0.35, 0.55, patch + (1.0 - COLOR.r) * 0.45 + max(shape, 0.0) * 0.15);
	f_a = mix(f_a, s_a, stones);
	f_n = mix(f_n, s_n, stones);
	f_arm = mix(f_arm, s_arm, stones);

	// Floor where the face looks up, broken along the rock's own bright parts.
	float up = smoothstep(0.55, 0.85, world_nrm.y + (r_a.r - 0.3) * 0.4);
	vec3 albedo = mix(r_a, f_a, up);
	vec2 fn = f_n * 2.0 - 1.0;
	vec3 bend = mix(r_bend * relief + macro, vec3(fn.x, 0.0, -fn.y) * relief + macro * 0.25, up);
	vec3 arm = mix(r_arm, f_arm, up);

	float ao = mix(1.0, smoothstep(0.0, 0.8, COLOR.r), ao_strength);
	ao *= mix(1.0, smoothstep(0.0, 0.5, COLOR.a), 0.22 * shape_paint);
	albedo *= 1.0 - shape * (shape > 0.0 ? 0.2 : 0.4);
	albedo *= mix(1.0, 0.5, run);
	ALBEDO = albedo * mix(0.55, 1.0, ao);
	AO = arm.r * ao;
	AO_LIGHT_AFFECT = 0.6;
	// Damp: walls a little glossier than their texture says.
	float rough = mix(arm.g * wet_roughness, arm.g, up) * (1.0 - 0.25 * shape);
	ROUGHNESS = clamp(rough * (1.0 - streak_gloss * run), 0.04, 1.0);
	METALLIC = 0.0;
	NORMAL = normalize((VIEW_MATRIX * vec4(normalize(world_nrm + bend), 0.0)).xyz);
}
