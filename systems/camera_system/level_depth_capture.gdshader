shader_type spatial;
// Writes this viewport's own depth, as linear metres from the camera, into
// its colour. Worn by one full-screen quad inside XRaySilhouettes' level
// depth SubViewport, whose camera mirrors the player's camera but leaves
// Unit.RENDER_LAYER out of its cull_mask. So the depth read here holds
// level geometry only, and the result is what xray_silhouette.gdshader
// tests a unit against: no unit, weapon or shield can ever hide a unit.
//
// Reading the depth texture puts this quad in the transparent pass, after
// every opaque object has written depth. The vertex shader pins it to the
// screen, so its mesh size and transform do not matter.
render_mode unshaded, blend_mix, depth_test_disabled, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled, ambient_light_disabled;

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest, repeat_disable;

// Written where nothing opaque was drawn (sky). Under a half float's max.
const float FAR = 60000.0;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	float depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	float distance = FAR;
	// Godot 4.3+ (Vulkan, reversed Z): 0 is the far plane, nothing drawn.
	if (depth > 0.0) {
		vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
		distance = min(-view.z / view.w, FAR);
	}
	ALBEDO = vec3(distance, 0.0, 0.0);
	ALPHA = 1.0;
}
