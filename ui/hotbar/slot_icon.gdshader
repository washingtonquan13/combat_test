shader_type canvas_item;
// The face of a dock slot (dock_slot.gd): a backdrop lit in the ability's
// icon_color, and the icon on it. Drawn on a ColorRect so the backdrop
// shows even with no icon; the Frame panel draws the border on top.
//
// A glyph icon (white art on black, the ability icons) is read as a mask:
// its brightness is the shape, recoloured in a cream-to-icon_color
// gradient with a drop shadow, so every icon shares one look whatever
// its file. Colour art (an item's picture) is drawn as it is.

uniform sampler2D icon_tex : source_color, filter_linear_mipmap;
uniform bool has_icon = false;
uniform bool glyph = true;
uniform vec4 tint : source_color = vec4(0.78, 0.74, 0.66, 1.0);
// The icon's share of the slot.
uniform float inset = 0.76;
// A circle (round toggle slots) instead of a rounded square.
uniform bool round = false;
uniform float corner_px = 3.0;
// Glyph brightness below `cut` is background; the mask ramps over `soft`.
uniform float cut = 0.15;
uniform float soft = 0.7;
uniform vec4 glyph_light : source_color = vec4(0.98, 0.96, 0.9, 1.0);
// How much the glyph takes icon_color, and the backdrop's glow from it.
uniform float glyph_tint : hint_range(0.0, 1.0) = 0.45;
uniform float backdrop_glow : hint_range(0.0, 1.0) = 0.3;
uniform vec4 backdrop_dark : source_color = vec4(0.055, 0.047, 0.039, 1.0);
uniform vec2 shadow_px = vec2(1.0, 1.5);
uniform float shadow_strength : hint_range(0.0, 1.0) = 0.8;
// State, set by dock_slot.gd: grey for the other set or disabled, and
// brighter while hovered.
uniform float saturation : hint_range(0.0, 1.0) = 1.0;
uniform float brightness = 1.0;

float mask_at(vec2 iu) {
	if (iu.x < 0.0 || iu.y < 0.0 || iu.x > 1.0 || iu.y > 1.0) {
		return 0.0;
	}
	vec4 t = texture(icon_tex, iu);
	float lum = dot(t.rgb, vec3(0.299, 0.587, 0.114)) * t.a;
	return clamp((lum - cut) / soft, 0.0, 1.0);
}

void fragment() {
	vec2 px = fwidth(UV);
	vec2 size = 1.0 / max(px, vec2(1e-5));

	// The slot's shape, so the backdrop's corners stay inside the frame.
	float shape;
	if (round) {
		float r = length(UV - 0.5) * 2.0;
		shape = 1.0 - smoothstep(1.0 - px.x * 2.0, 1.0, r);
	} else {
		vec2 p = (UV - 0.5) * size;
		vec2 q = abs(p) - size * 0.5 + corner_px;
		float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - corner_px;
		shape = 1.0 - smoothstep(-1.0, 0.0, d);
	}

	// Backdrop: icon_color glowing from just above the middle into dark.
	float r = clamp(length((UV - vec2(0.5, 0.42)) * vec2(1.0, 1.1)) / 0.72, 0.0, 1.0);
	vec3 col = mix(tint.rgb * backdrop_glow, backdrop_dark.rgb, r);
	// A faint top-edge light, so the face reads as a recessed tile.
	col += vec3(1.0, 0.94, 0.82) * 0.06 * (1.0 - smoothstep(0.0, 3.0 * px.y, UV.y));

	if (has_icon) {
		vec2 iu = (UV - 0.5) / inset + 0.5;
		if (glyph) {
			float m = mask_at(iu);
			float sh = mask_at(iu - shadow_px * px / inset);
			col *= 1.0 - shadow_strength * sh * (1.0 - m);
			vec3 g = mix(glyph_light.rgb, tint.rgb, glyph_tint) * mix(1.0, 0.72, clamp(iu.y, 0.0, 1.0));
			col = mix(col, g, m);
		} else if (iu.x >= 0.0 && iu.y >= 0.0 && iu.x <= 1.0 && iu.y <= 1.0) {
			vec4 t = texture(icon_tex, iu);
			col = mix(col, t.rgb, t.a);
		}
	}

	float lum = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(vec3(lum), col, saturation) * brightness;
	COLOR = vec4(col, shape * COLOR.a);
}
