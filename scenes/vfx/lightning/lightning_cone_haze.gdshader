shader_type spatial;
// The faint glowing body that fills an electric cone (lightning_cone.gd).
// Worn by an open CylinderMesh whose narrow top sits at the hand. It is
// brightest by the hand and fades out along the cone. It is soft at its
// silhouette, where the view grazes the surface, so it reads as a volume
// of light, not a shell. Streaks of noise rush outward along it.
// Additive and unshaded.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

uniform sampler2D noise : filter_linear_mipmap, repeat_enable;
uniform vec3 color : source_color = vec3(0.35, 0.45, 1.0);
// Set per frame: overall brightness, and how far along it has spread.
uniform float strength = 1.0;
uniform float reveal = 1.0;
uniform float time = 0.0;
// The mesh's height, so the vertex shader can tell how far along it is.
uniform float height = 9.0;
// How fast the brightness dies along the cone, and the streaks' speed.
uniform float falloff = 3.5;
uniform float rush = 2.5;

varying float along;
varying float around;

void vertex() {
	// +Y (the narrow top) is the hand.
	along = 0.5 - VERTEX.y / height;
	around = atan(VERTEX.z, VERTEX.x) / TAU;
}

void fragment() {
	float facing = abs(dot(normalize(NORMAL), VIEW));
	float soft = facing;
	float body = exp(-along * falloff) * smoothstep(1.0, 0.7, along);
	body *= smoothstep(reveal, reveal - 0.12, along);
	// Stretched along the cone, so it reads as streaks rushing outward.
	float streak = texture(noise, vec2(around * 6.0, along * 0.5 - time * rush * 0.3)).r;
	ALBEDO = color * strength * soft * body * (0.5 + streak);
}
