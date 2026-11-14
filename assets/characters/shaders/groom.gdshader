shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

// Hair cards grown by tools/characters/groom.py. The atlas holds strands, not
// colour: R a random id per strand, G shading, B how far along its strand,
// A coverage. The colour is made here, so every character shares one atlas.
//
// Coverage is hashed (dithered) rather than blended: the cards write depth,
// sort themselves and cast shadows strand by strand, and the project's TAA
// smooths the dither into soft strands. The light is Kajiya-Kay's: two
// highlights stretched along the strands, the second shifted towards the tips
// and tinted by the hair.

uniform sampler2D strands : filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec4 hair_color : source_color = vec4(0.25, 0.17, 0.11, 1.0);
// How much single strands and whole cards differ in brightness.
uniform float strand_variation : hint_range(0.0, 1.0) = 0.3;
uniform float card_variation : hint_range(0.0, 1.0) = 0.15;
// Roots darker, tips lighter.
uniform float root_darkness : hint_range(0.0, 1.0) = 0.8;
uniform float tip_lightness : hint_range(1.0, 2.0) = 1.2;
// The inner layer, close to the scalp, sits in the hair's own shadow.
uniform float inner_shadow : hint_range(0.0, 1.0) = 0.2;
// How dark the shadowed strands in the atlas get.
uniform float strand_shading : hint_range(0.0, 1.0) = 0.35;
// Thin strands fade out in the smaller mips; this keeps the hair's coverage
// as it gets further away.
uniform float mip_coverage : hint_range(0.0, 1.0) = 0.3;

uniform float roughness : hint_range(0.0, 1.0) = 0.7;
uniform float specular_level : hint_range(0.0, 1.0) = 0.2;
uniform float primary_strength : hint_range(0.0, 2.0) = 0.03;
uniform float primary_sharpness = 80.0;
uniform float primary_shift = -0.08;
uniform float secondary_strength : hint_range(0.0, 2.0) = 0.12;
uniform float secondary_sharpness = 40.0;
// A card is flat, so its highlight would light it as one block; each strand
// catches a different share of it instead.
uniform float highlight_breakup : hint_range(0.0, 1.0) = 0.8;
uniform float secondary_shift = 0.12;
// Light through thin hair, seen with the sun behind.
uniform float translucency : hint_range(0.0, 1.0) = 0.3;
// Softens the terminator: hair is a volume, not a surface.
uniform float wrap : hint_range(0.0, 1.0) = 0.4;
// Light bounces many times inside a head of hair, so it is far brighter in
// shade than its colour alone would make it. Ambient light sees the hair this
// many times brighter; the direct light below divides it back out.
uniform float scatter : hint_range(1.0, 6.0) = 3.0;

varying vec3 strand;
varying float sheen;

void fragment() {
	vec4 d = texture(strands, UV);
	float mip = max(textureQueryLod(strands, UV).x, 0.0);
	float layer = COLOR.r;

	vec3 base = hair_color.rgb;
	base *= 1.0 + (d.r - 0.5) * strand_variation;
	base *= 1.0 + (COLOR.g - 0.5) * card_variation;
	base *= mix(root_darkness, 1.0, smoothstep(0.0, 0.35, d.b));
	base *= mix(1.0, tip_lightness, smoothstep(0.55, 1.0, d.b));
	base *= mix(1.0 - inner_shadow, 1.0, smoothstep(0.3, 0.85, layer));

	ALBEDO = base * mix(1.0 - strand_shading, 1.0, d.g) * scatter;
	ALPHA = clamp(d.a * (1.0 + mip * mip_coverage), 0.0, 1.0);
	ALPHA_HASH_SCALE = 1.0;
	ROUGHNESS = roughness;
	SPECULAR = specular_level;
	// The card's normals point away from the head, not off the card; seen
	// from behind, keep them pointing away.
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	// The strand's direction: along the card's V, which the baked tangents
	// carry as the binormal. Kajiya-Kay needs only its line, not its sign.
	sheen = mix(1.0 - highlight_breakup, 1.0, d.r * d.r) * smoothstep(0.1, 0.5, d.b);
	strand = normalize(BINORMAL - NORMAL * dot(BINORMAL, NORMAL) + NORMAL * 1e-4);
}

float kajiya(vec3 t, vec3 h, float sharpness) {
	float th = dot(t, h);
	return pow(sqrt(max(1.0 - th * th, 0.0)), sharpness) * smoothstep(-1.0, 0.0, th);
}

void light() {
	float ndl = dot(NORMAL, LIGHT);
	float lit = clamp((ndl + wrap) / (1.0 + wrap), 0.0, 1.0);
	DIFFUSE_LIGHT += lit * ATTENUATION * LIGHT_COLOR / PI / scatter;

	vec3 h = normalize(LIGHT + VIEW);
	vec3 t1 = normalize(strand + NORMAL * primary_shift);
	vec3 t2 = normalize(strand + NORMAL * secondary_shift);
	float facing = smoothstep(-0.1, 0.3, ndl);
	vec3 spec = vec3(kajiya(t1, h, primary_sharpness) * primary_strength)
		+ ALBEDO / scatter * kajiya(t2, h, secondary_sharpness) * secondary_strength * 2.0;
	SPECULAR_LIGHT += spec * sheen * facing * ATTENUATION * LIGHT_COLOR / PI;

	float behind = pow(clamp(dot(VIEW, -LIGHT), 0.0, 1.0), 4.0);
	DIFFUSE_LIGHT += behind * translucency * ATTENUATION * LIGHT_COLOR / PI / scatter;
}
