shader_type spatial;
// Inverted-hull outline: push vertices outward along their normal, draw
// only the resulting back faces (cull_front), unshaded solid color. The
// sliver of inflated back-face geometry that pokes out past the
// original mesh's silhouette, from the camera's point of view, is what
// reads as an outline.
//
// Works correctly on animated/skinned meshes with NO special handling —
// Godot applies skeletal skinning to VERTEX/NORMAL before this shader's
// vertex() function runs, so they already reflect the current animated
// pose.
//
// If nothing shows, or the whole mesh renders solid instead of just an
// outline: try switching cull_front to cull_back below — some imported
// meshes have inverted winding order relative to what's assumed here.
render_mode unshaded, cull_front;

uniform vec4 outline_color : source_color = vec4(1.0, 0.85, 0.2, 1.0);
uniform float outline_width : hint_range(0.0, 0.1) = 0.02;
// How far the hull is pushed back from the camera, in metres. Without it
// the hull's back faces come forward of the body wherever the body folds:
// eye sockets, the mouth, a collar, hair, a sleeve against the chest. Each
// fold then draws as a line of outline across the body, and a detailed
// model is outlined everywhere instead of around its edge. Pushed back
// along the view ray, a vertex stays at the same place on screen, so the
// rim around the silhouette is untouched, while every fold, being
// shallower than this, sinks behind the surface in front of it.
uniform float depth_push : hint_range(0.0, 1.0) = 0.25;

void vertex() {
	vec4 view = MODELVIEW_MATRIX * vec4(VERTEX + NORMAL * outline_width, 1.0);
	view.xyz += normalize(view.xyz) * depth_push;
	POSITION = PROJECTION_MATRIX * view;
}

void fragment() {
	ALBEDO = outline_color.rgb;
	ALPHA = outline_color.a;
}
