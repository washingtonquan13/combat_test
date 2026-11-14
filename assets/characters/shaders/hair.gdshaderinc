// Shared by hair.gdshader (the solid core of the cards) and hair_edge.gdshader
// (their soft, see-through fringe), so both shade the same.

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic;
// The colour the hair is dyed to. The texture's own shading (strands, roots,
// highlights) is kept and only its overall colour is replaced.
uniform vec4 hair_color : source_color = vec4(0.25, 0.17, 0.11, 1.0);
// 0 keeps the texture's colour, 1 dyes it fully to hair_color.
uniform float dye : hint_range(0.0, 1.0) = 0.0;
// How far the strand detail in the texture is pushed.
uniform float strand_contrast : hint_range(0.5, 3.0) = 1.4;
uniform float alpha_cut : hint_range(0.0, 1.0) = 0.5;
// The textures' alpha edges are thin and painted in chunks, which reads as a
// hard, jagged hairline. The fringe fades out over a blurred copy of the
// alpha instead: how blurred, and how strong.
uniform float fringe_blur = 4.0;
uniform float fringe_opacity : hint_range(0.0, 1.0) = 0.6;

uniform float roughness : hint_range(0.0, 1.0) = 0.55;
uniform float specular_level : hint_range(0.0, 1.0) = 0.3;
// A highlight stretched across the strands, as real hair has.
uniform float anisotropy : hint_range(-1.0, 1.0) = 0.5;
// Which way the strands run on the card, in its tangent space.
uniform vec2 strand_direction = vec2(0.0, 1.0);
// Light through thin hair, seen with the sun behind.
uniform float translucency : hint_range(0.0, 1.0) = 0.35;

float hair_luma(vec3 c) {
	return dot(c, vec3(0.299, 0.587, 0.114));
}

// The hair's colour around uv with the strand detail averaged out. Some
// textures are black where they are see-through, so the average is taken
// over the hair only (divided by its coverage).
vec3 hair_base(vec2 uv) {
	vec4 mean = textureLod(albedo_texture, uv, 6.0);
	return mix(mean.rgb / max(mean.a, 0.05), hair_color.rgb, dye);
}

// The card's colour and coverage at uv.
vec4 hair_sample(vec2 uv) {
	vec4 t = texture(albedo_texture, uv);
	vec4 mean = textureLod(albedo_texture, uv, 6.0);
	float detail = clamp(pow(hair_luma(t.rgb) / max(hair_luma(mean.rgb / max(mean.a, 0.05)), 0.001), strand_contrast), 0.0, 3.0);
	return vec4(hair_base(uv) * detail, t.a);
}

// Coverage of the soft fringe around the solid hair at uv.
float hair_fringe(vec2 uv, float alpha) {
	float soft = textureLod(albedo_texture, uv, fringe_blur).a;
	return max(alpha, soft * fringe_opacity);
}
