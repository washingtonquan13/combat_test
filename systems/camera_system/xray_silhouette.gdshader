shader_type spatial;
// X-ray silhouette: a unit drawn through whatever hides it, and ONLY
// where it is hidden. Worn as a material_overlay on a unit's body meshes
// by XRaySilhouettes (see xray_silhouettes.gd for who gets one and why).
//
// No stencil. The pass ignores the depth buffer (depth_test_disabled), so
// every fragment of the body reaches fragment(), wall or no wall. It then
// asks the depth texture what the opaque scene actually put at this
// pixel: if that is the unit itself (or something behind it), the body is
// visible and the fragment is discarded; if it is something nearer than
// the body by more than occlusion_bias, the body is hidden there and the
// tint is drawn.
//
// The bias is what keeps a visible unit clean. Without it, an arm swung
// in front of the torso is "something nearer" and the torso would tint
// through the arm. 0.3 m is about half a body's depth: a wall has to be
// clearly in front of the unit before it counts.
//
// Only OPAQUE geometry writes the depth texture. That is the point: a wall
// the camera has faded (GeometryInstance3D.transparency) has left the
// opaque pass, so a unit behind a faded wall is just seen, not tinted;
// clouds, fire and fog never trigger it either.
//
// Skinned meshes need nothing special: overlays run on the skinned
// vertices, so the silhouette follows the animated pose.
render_mode unshaded, blend_mix, depth_test_disabled, depth_draw_never, cull_back, fog_disabled;

uniform vec4 silhouette_color : source_color = vec4(0.34, 0.71, 0.91, 1.0);
// Flat tint across the whole hidden body.
uniform float fill_alpha : hint_range(0.0, 1.0) = 0.22;
// Extra alpha at grazing angles, so the shape reads as a figure, not a blob.
uniform float rim_alpha : hint_range(0.0, 1.0) = 0.55;
uniform float rim_power : hint_range(0.5, 8.0) = 2.0;
// Metres something must sit in front of the body before it counts as hiding it.
uniform float occlusion_bias : hint_range(0.0, 2.0) = 0.3;

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest, repeat_disable;

void fragment() {
	float depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	// Godot 4.3+ (Vulkan, reversed Z): the raw depth IS the NDC z.
	vec4 scene_view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float scene_distance = -scene_view.z / scene_view.w;
	float own_distance = -VERTEX.z;
	if (own_distance <= scene_distance + occlusion_bias) {
		discard;
	}

	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float rim = pow(1.0 - facing, rim_power);
	ALBEDO = silhouette_color.rgb;
	ALPHA = clamp((fill_alpha + rim * rim_alpha) * silhouette_color.a, 0.0, 1.0);
}
