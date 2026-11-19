shader_type spatial;
// An overworld door's marker: a column of light standing on a glowing
// ring. One shader for both parts; `part` picks which. The column is an
// open cylinder that fades out going up and is brightest along its
// silhouette, so it reads as a volume of light rather than a tube; the
// ring has a soft fill and a ripple running outward from the centre.
// `hot` (per instance, set by overworld_door.gd) brightens it while the
// commanded avatar stands inside.
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform vec4 tint : source_color = vec4(1.0, 0.7, 0.06, 1.0);
// 0 = the column, 1 = the ground ring.
uniform int part = 0;
// The column mesh's height, to turn its local y into 0 (bottom) to 1 (top).
uniform float column_height = 2.5;
uniform float strength = 0.95;
instance uniform float hot = 0.0;

varying float height;

void vertex() {
	height = clamp(VERTEX.y / column_height + 0.5, 0.0, 1.0);
}

void fragment() {
	float pulse = 0.88 + 0.12 * sin(TIME * 2.4);
	float boost = 1.0 + hot * 0.8;
	if (part == 0) {
		float fade = pow(1.0 - height, 1.25);
		// Brightest edge-on, faint face-on: a volume, not a pipe.
		float edge = 1.0 - abs(dot(normalize(NORMAL), VIEW));
		float a = fade * mix(0.55, 1.0, edge) * strength;
		// A brighter lip where the column meets the ground.
		a += smoothstep(0.08, 0.0, height) * 0.35;
		ALBEDO = mix(tint.rgb, vec3(1.0, 0.95, 0.7), 0.3 * fade);
		ALPHA = clamp(a * pulse * boost, 0.0, 1.0);
	} else {
		float r = length(UV * 2.0 - 1.0);
		if (r > 1.0) {
			discard;
		}
		float ring = smoothstep(0.80, 0.88, r) * (1.0 - smoothstep(0.94, 1.0, r));
		float fill = 0.38 * (1.0 - r * 0.5);
		float wave = fract(TIME * 0.45);
		float ripple = (1.0 - smoothstep(0.0, 0.06, abs(r - wave * 0.85))) * (1.0 - wave) * 0.5;
		ALBEDO = mix(tint.rgb, vec3(1.0), ring * 0.3);
		// The fill stays as it is when hot, so the avatar inside still shows.
		ALPHA = clamp(((ring + ripple) * boost + fill) * pulse, 0.0, 1.0);
	}
}
