shader_type spatial;
// The hover outline as a pass of the body's own materials (UnitOutline
// appends it to the end of each surface's next_pass chain). The same
// inverted hull as outline.gdshader, grown a fixed number of pixels along
// the screen-space normal and pushed back from the camera, but drawn by the
// mesh itself, so it goes wherever the mesh is drawn: a lean of the Body,
// a crawl, a cinematic copy. A separate hull mesh beside the body did not,
// and showed as a ghost a frame behind in every turn.
//
// The colour is per instance (GeometryInstance3D instance uniform), so one
// shared pass serves every unit and shared materials outline only the mesh
// that is lit. Alpha 0, the default, is off: every vertex lands on one
// point outside the view and nothing is rasterised.
//
// outline_color holds instance-uniform slot 0 of every mesh it is appended
// to: two instance uniforms at one index in one instance's materials are
// one value. Body shaders' own instance uniforms take instance_index(1) and
// up (the CC shaders do), or clearing the outline overwrites them.
render_mode unshaded, cull_front;

instance uniform vec4 outline_color : source_color = vec4(0.0);
uniform float outline_pixels : hint_range(0.0, 8.0, 0.25) = 1.5;
// See outline.gdshader: folds (eye sockets, collars, sleeves) sink behind
// the surface in front of them instead of drawing as lines across the body.
uniform float depth_push : hint_range(0.0, 1.0) = 0.25;

void vertex() {
	if (outline_color.a <= 0.0) {
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);
	} else {
		vec4 view = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
		view.xyz += normalize(view.xyz) * depth_push;
		vec4 clip = PROJECTION_MATRIX * view;
		vec3 view_normal = mat3(MODELVIEW_MATRIX) * NORMAL;
		vec2 screen_normal = (PROJECTION_MATRIX * vec4(view_normal, 0.0)).xy;
		if (dot(screen_normal, screen_normal) > 1e-10) {
			clip.xy += normalize(screen_normal) * outline_pixels * 2.0 / VIEWPORT_SIZE * clip.w;
		}
		POSITION = clip;
	}
}

void fragment() {
	ALBEDO = outline_color.rgb;
	ALPHA = outline_color.a;
}
