shader_type canvas_item;
// A round pool gauge (dock.gd's HP and FP globes): the TextureRect's
// texture masked to a circle, liquid tinted in from the bottom up to
// `fill`, the emptied top darkened, a bright surface line where they meet
// and a metal rim round the edge.

uniform float fill : hint_range(0.0, 1.0) = 1.0;
// Liquid colour at the surface and at the bottom; alpha is how much it
// covers the texture underneath (low for the portrait, high for FP).
uniform vec4 liquid_top : source_color = vec4(0.78, 0.12, 0.12, 0.12);
uniform vec4 liquid_bottom : source_color = vec4(0.59, 0.0, 0.0, 0.38);
uniform vec4 lost_color : source_color = vec4(0.0, 0.0, 0.0, 0.6);
uniform vec4 surface_color : source_color = vec4(1.0, 0.47, 0.47, 0.8);
uniform vec4 rim_color : source_color = vec4(0.66, 0.51, 0.24, 1.0);
uniform float rim_px = 3.0;
uniform float surface_px = 2.0;
// Inner shadow towards the rim, 0..1.
uniform float vignette = 0.55;
// The part of the texture shown, so a non-square portrait still fills a
// round globe (the TextureRect itself stretches, it does not crop: its
// UV must stay the rect's 0..1 for the circle). dock.gd sets these from
// the texture's aspect: the short side whole, the long side centred
// (or, for a tall portrait, nearer the top, where the face is).
uniform vec2 uv_scale = vec2(1.0);
uniform vec2 uv_offset = vec2(0.0);

void fragment() {
	vec2 c = UV - vec2(0.5);
	float r = length(c) * 2.0;
	// Pixels per unit of r, so the rim and the edge stay crisp at any size.
	float px = fwidth(r);
	float inside = 1.0 - smoothstep(1.0 - px, 1.0, r);

	vec4 base = texture(TEXTURE, uv_offset + UV * uv_scale);
	vec3 col = base.rgb;

	float height = 1.0 - UV.y;
	if (height <= fill) {
		float t = fill > 0.0 ? clamp(height / fill, 0.0, 1.0) : 0.0;
		vec4 liquid = mix(liquid_bottom, liquid_top, t);
		col = mix(col, liquid.rgb, liquid.a);
	} else {
		col = mix(col, lost_color.rgb, lost_color.a);
	}

	float line_px = fwidth(UV.y);
	float surface = 1.0 - smoothstep(0.0, surface_px * line_px, abs(height - fill));
	if (fill > 0.001 && fill < 0.999) {
		col = mix(col, surface_color.rgb, surface * surface_color.a);
	}

	col *= 1.0 - vignette * smoothstep(0.55, 1.0, r);

	float rim_w = rim_px * px;
	float rim = smoothstep(1.0 - rim_w - px, 1.0 - rim_w, r);
	col = mix(col, rim_color.rgb, rim * rim_color.a);

	COLOR = vec4(col, inside * base.a);
}
