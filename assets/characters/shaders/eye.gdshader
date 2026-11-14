shader_type spatial;
render_mode cull_back;

// Eyes for the baked MPFB humans (their "high-poly" eyes). Each eye is a
// ball, its iris set back inside it, under a cornea shell whose texture is
// clear; drawn as imported, the whole eye goes through the transparent pass
// and reads as a flat, unshadowed white. Here the shell is dropped and the
// ball drawn opaque, with what the cornea and lids would give it: a wet
// shine, an iris seen a little through the cornea's depth, the darker ring
// round the iris, and the shadow the lids cast at the corners and under the
// upper lid.
//
// The places below are MPFB's eye texture's (both eyes share it).

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec2 iris_centre_a = vec2(0.289, 0.717);
uniform vec2 iris_centre_b = vec2(0.705, 0.304);
uniform float iris_radius = 0.106;
uniform vec2 cornea_centre = vec2(0.935, 0.933);
uniform float cornea_radius = 0.075;

// How far the iris seems to sit under the cornea, in UV per unit of slant.
uniform float iris_depth : hint_range(0.0, 0.05) = 0.012;
uniform float iris_brightness : hint_range(0.5, 2.0) = 1.15;
uniform float sclera_brightness : hint_range(0.3, 1.0) = 0.8;
// MPFB's brown iris is red; this much of its colour is kept.
uniform float iris_saturation : hint_range(0.0, 1.0) = 0.55;
uniform float limbus : hint_range(0.0, 1.0) = 0.55;
// How dark the lids leave the ball at the corners and under the upper lid.
uniform float lid_shadow : hint_range(0.0, 1.0) = 0.8;

void fragment() {
	if (distance(UV, cornea_centre) < cornea_radius) {
		discard;
	}
	vec2 c = distance(UV, iris_centre_a) < distance(UV, iris_centre_b) ? iris_centre_a : iris_centre_b;
	vec2 d = UV - c;
	float r = length(d);
	float iris = 1.0 - smoothstep(iris_radius * 0.9, iris_radius * 1.05, r);

	vec2 slant = vec2(dot(VIEW, TANGENT), dot(VIEW, BINORMAL)) / max(dot(VIEW, NORMAL), 0.3);
	vec3 col = texture(albedo_texture, UV - slant * iris_depth * iris).rgb;
	float luma = dot(col, vec3(0.3, 0.55, 0.15));
	col = mix(col, mix(vec3(luma), col, iris_saturation), iris);
	col *= mix(sclera_brightness * vec3(1.0, 0.95, 0.91), vec3(iris_brightness), iris);
	float ring = exp(-pow((r - iris_radius) / (iris_radius * 0.15), 2.0));
	col *= 1.0 - limbus * ring;

	// Up on the ball is -v in its UVs. The lids leave about r < 0.17 open
	// across and less up and down; the upper lid overhangs and shades.
	float across = smoothstep(0.15, 0.21, r);
	float under_lid = smoothstep(0.02, 0.12, -d.y);
	float shade = clamp(max(across, under_lid * 0.85), 0.0, 1.0) * lid_shadow;

	ALBEDO = col * (1.0 - shade * 0.6);
	AO = 1.0 - shade;
	AO_LIGHT_AFFECT = 0.85;
	ROUGHNESS = 0.55;
	SPECULAR = 0.3;
	CLEARCOAT = 0.5 * (1.0 - shade);
	CLEARCOAT_ROUGHNESS = 0.02;
}
