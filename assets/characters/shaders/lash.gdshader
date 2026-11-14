shader_type spatial;
render_mode cull_disabled;

// Eyelashes (and brows) for the baked MPFB humans: their cards' alpha drawn
// hashed, not blended, so they sort with the eyes and lids, cast their
// shadow and stay fine; the hairs take one colour (the character's hair,
// darkened) rather than the texture's. TAA smooths the hash.

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 hair_color : source_color = vec4(0.25, 0.17, 0.11, 1.0);
uniform float darken : hint_range(0.0, 1.0) = 0.3;
// Thins the hairs: alpha is raised to this.
uniform float thin : hint_range(0.5, 3.0) = 1.4;
uniform float opacity : hint_range(0.0, 1.0) = 1.0;
// The lower lashes (the texture's lower half) are shorter and sparser.
uniform float lower_opacity : hint_range(0.0, 1.0) = 0.45;

void fragment() {
	float a = texture(albedo_texture, UV).a;
	ALBEDO = hair_color.rgb * darken;
	ROUGHNESS = 0.6;
	SPECULAR = 0.3;
	ALPHA = pow(a, thin) * opacity * (UV.y > 0.5 ? lower_opacity : 1.0);
	ALPHA_HASH_SCALE = 1.0;
}
