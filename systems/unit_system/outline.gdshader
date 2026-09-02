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

void vertex() {
	VERTEX += NORMAL * outline_width;
}

void fragment() {
	ALBEDO = outline_color.rgb;
	ALPHA = outline_color.a;
}
