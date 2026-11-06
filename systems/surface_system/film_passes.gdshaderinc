// fragment() for a decal_surface.gd film shader, included last. The
// shader defines, before including this:
//   float film_height(vec2 uv)            thickness at uv, 0 where there is none
//   vec4  film_albedo(vec2 uv, float h)   color, alpha = coverage
//   vec3  film_emission(vec2 uv, float h) glow (black for most films)
// uv runs 0..1 across the decal; meters(uv) is the world point. Drawing
// all passes from film_height() keeps the bumps and glow exactly where
// the film is.

// Two layers drifting opposite ways round the loop, so ripples shimmer
// rather than slide.
float ripples(vec2 p, vec2 drift) {
	return fbm(p + drift) * 0.6 + fbm(p * 1.7 - drift * 1.3 + 5.0) * 0.4;
}

void fragment() {
	vec2 uv = UV;
	float h = film_height(uv);
	if (film_pass == 0) {
		COLOR = film_albedo(uv, h);
	} else if (film_pass == 2) {
		COLOR = vec4(film_emission(uv, h), 1.0);
	} else {
		vec2 e = SCREEN_PIXEL_SIZE * 1.5;
		float turn = loop_phase * 6.2831853;
		vec2 drift = vec2(cos(turn), sin(turn)) * ripple_drift;
		vec2 m = meters(uv) * ripple_scale;
		vec2 step_m = e * size_m * ripple_scale;
		float ripple_x = (ripples(m + vec2(step_m.x, 0.0), drift) - ripples(m - vec2(step_m.x, 0.0), drift)) * ripple_strength;
		float ripple_y = (ripples(m + vec2(0.0, step_m.y), drift) - ripples(m - vec2(0.0, step_m.y), drift)) * ripple_strength;
		float dx = (film_height(uv + vec2(e.x, 0.0)) - film_height(uv - vec2(e.x, 0.0)) + ripple_x * h) / (2.0 * e.x * size_m.x);
		float dy = (film_height(uv + vec2(0.0, e.y)) - film_height(uv - vec2(0.0, e.y)) + ripple_y * h) / (2.0 * e.y * size_m.y);
		vec3 n = normalize(vec3(-dx * bumpiness, dy * bumpiness, 1.0));
		COLOR = vec4(n * 0.5 + 0.5, 1.0);
	}
}
