shader_type canvas_item;
// Puts a render of the wheel at its current turn, with motion blur. Each wedge
// comes from the render of that wedge's outcome, so one set of renders covers
// every target number; the wedges meet under a wire or a gap that is the same
// in every render, so the switch between renders never shows.

// One slice per outcome, in the order of OddsWheel.Kind, then the pegs.
uniform sampler2DArray renders : filter_linear_mipmap, repeat_disable;
// Where the wheel's axis is in the render.
uniform vec2 pivot = vec2(0.5);
// The wheel's `spin` when it was rendered, and now, in radians, clockwise.
uniform float baked_spin = 0.0;
uniform float spin = 0.0;
// How far the wheel moves while the shutter is open, in radians.
uniform float blur = 0.0;
// When not negative, draw this slice all the way round.
uniform int fixed_slice = -1;

// Per wedge: start clockwise from the bottom and size, radians, and outcome.
uniform float starts[16];
uniform float spans[16];
uniform int kinds[16];

uniform int landed = -1;
uniform float dim = 0.0;
uniform float dim_strength = 0.68;
uniform vec3 backing : source_color;
uniform vec3 highlight : source_color;
// In UV: the visible wedge between hub and rim, and the width of the outline
// round the wedge that came up.
uniform float hub_edge = 0.1;
uniform float rim_edge = 0.4;
uniform float highlight_width = 0.008;


int wedge_at(float angle) {
	for (int i = 15; i > 0; i--) {
		if (angle >= starts[i]) {
			return i;
		}
	}
	return 0;
}


vec4 render_at(vec2 from_pivot, float turn, float lod) {
	float c = cos(turn);
	float s = sin(turn);
	vec2 p = vec2(c * from_pivot.x + s * from_pivot.y, c * from_pivot.y - s * from_pivot.x);
	if (fixed_slice >= 0) {
		return textureLod(renders, vec3(p + pivot, float(fixed_slice)), lod);
	}
	float angle = mod(atan(p.y, p.x) - PI * 0.5 - baked_spin, TAU);
	int i = wedge_at(angle);
	vec4 colour = textureLod(renders, vec3(p + pivot, float(kinds[i])), lod);
	if (dim > 0.0) {
		if (i == landed) {
			float r = length(p);
			float across = min(angle - starts[i], starts[i] + spans[i] - angle) * r;
			float from_edge = min(across, min(r - hub_edge, rim_edge - r));
			float line = 1.0 - smoothstep(0.0, highlight_width, from_edge);
			colour.rgb = mix(colour.rgb, highlight, line * dim * 0.85);
		} else {
			colour.rgb = mix(colour.rgb, backing, dim_strength * dim);
		}
	}
	return colour;
}


void fragment() {
	vec2 from_pivot = UV - pivot;
	float texels = max(length(dFdx(UV)), length(dFdy(UV))) * float(textureSize(renders, 0).x);
	float lod = max(0.0, log2(texels));
	float turn = spin - baked_spin;
	if (blur <= 0.0) {
		COLOR = render_at(from_pivot, turn, lod);
	} else {
		int steps = clamp(int(ceil(blur * 120.0)), 2, 24);
		// Each pixel starts its steps somewhere else, which trades the ghost
		// images few steps would leave for fine grain nobody sees in motion.
		float jitter = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
		vec4 sum = vec4(0.0);
		for (int n = 0; n < steps; n++) {
			float through = (float(n) + jitter) / float(steps) - 0.5;
			vec4 colour = render_at(from_pivot, turn + through * blur, lod);
			sum += vec4(colour.rgb * colour.a, colour.a);
		}
		COLOR = sum.a > 0.0 ? vec4(sum.rgb / sum.a, sum.a / float(steps)) : vec4(0.0);
	}
}
