shader_type spatial;
// Additive — this is the only line layer (two earlier, discarded
// variants: a separate crisp regular-alpha "core" line under this glow,
// and a dash pattern sampled along the ribbon's length; both removed
// per explicit request, see movement_indicator.gd's header). Explicit
// blend_add/unshaded rather than relying on any default — Godot's
// editor fills in a sensible default for a shader that writes ALPHA
// without declaring a blend mode, but an EXPORTED build does not
// inherit that same default, which would silently break this line in a
// real export (this project has never actually run one yet, so this
// class of bug would otherwise go unnoticed until export day).
render_mode unshaded, blend_add, cull_disabled;

// Soft falloff across the ribbon's width. UV.y runs 0 (one edge) to 1
// (the other edge); this is the fraction of that range spent fading in
// from each edge — smaller reads as a crisper edge, larger (up to 0.5,
// which fades continuously with no flat plateau at all) as a softer
// gradient. Kept high/soft by default since this falloff IS the whole
// visual now, not a halo around something crisper.
uniform float edge_softness : hint_range(0.01, 0.5) = 0.5;
// Multiplies final brightness. The scene's glow_hdr_threshold (see
// main.tscn's WorldEnvironment, left at Environment's engine default of
// 1.0) is what decides whether something actually blooms — values here
// above 1.0 intentionally push past that threshold so this material's
// output blooms without lowering the threshold for the rest of the game.
uniform float brightness_boost : hint_range(0.1, 5.0) = 2.5;

void fragment() {
	float edge = smoothstep(0.0, edge_softness, UV.y) * smoothstep(1.0, 1.0 - edge_softness, UV.y);
	float brightness = edge * brightness_boost;
	// COLOR is the per-vertex color set via surface_set_color() in
	// movement_indicator.gd — this is how path_in_range_color (white) vs
	// path_out_of_range_color (red) still works with one shared material
	// rather than needing a separate material per color.
	ALBEDO = COLOR.rgb * brightness;
	ALPHA = COLOR.a * brightness;
}
