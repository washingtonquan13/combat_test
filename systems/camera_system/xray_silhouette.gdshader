shader_type spatial;
// X-ray silhouette: a unit drawn through whatever hides it, and ONLY
// where it is hidden. Worn as a material_overlay on a unit's body meshes
// by XRaySilhouettes (see xray_silhouettes.gd for who gets one and why).
//
// No stencil. The pass ignores the depth buffer (depth_test_disabled), so
// every fragment of the body reaches fragment(), wall or no wall. It then
// asks level_depth how far away the LEVEL is at this pixel: if the level
// is behind the body, the body is in view there and the fragment is
// discarded; if the level is nearer by more than occlusion_bias, a wall
// hides the body there and the tint is drawn.
//
// level_depth, not the screen's own depth texture, because the screen's
// holds every opaque thing: another unit, a shield, the unit's own arm.
// Tested against that, a unit behind a unit tinted, and so did a torso
// behind its own swung arm. level_depth is rendered by XRaySilhouettes
// from a camera that mirrors this one and leaves Unit.RENDER_LAYER out
// (see level_depth_capture.gdshader), so only level geometry hides.
//
// The bias covers a foot sunk a little into the floor and the coarser
// edges of a reduced-resolution level_depth. Only opaque geometry is in
// it: clouds, fire and fog never trigger the tint.
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
uniform float occlusion_bias : hint_range(0.0, 2.0) = 0.1;

// Linear metres to the nearest level surface, in R. Set by XRaySilhouettes.
uniform sampler2D level_depth : filter_nearest, repeat_disable;

void fragment() {
	float scene_distance = textureLod(level_depth, SCREEN_UV, 0.0).r;
	float own_distance = -VERTEX.z;
	if (own_distance <= scene_distance + occlusion_bias) {
		discard;
	}

	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float rim = pow(1.0 - facing, rim_power);
	ALBEDO = silhouette_color.rgb;
	ALPHA = clamp((fill_alpha + rim * rim_alpha) * silhouette_color.a, 0.0, 1.0);
}
