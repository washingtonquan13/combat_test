// fragment() for a decal_surface.gd film shader, included last. The
// shader defines, before including this:
//   float film_height(vec2 p)            thickness at p, 0 where there's none
//   vec4  film_albedo(vec2 p, float h)   color, alpha = coverage
//   vec3  film_emission(vec2 p, float h) glow (black for most films)
// p runs -1..1 across the decal. Drawing all passes from film_height()
// keeps the bumps and glow exactly where the film is.

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float h = film_height(p);
	if (film_pass == 0) {
		COLOR = film_albedo(p, h);
	} else if (film_pass == 2) {
		COLOR = vec4(film_emission(p, h), 1.0);
	} else {
		float e = SCREEN_PIXEL_SIZE.x * 3.0;
		vec2 m = p * radius_m * ripple_scale;
		float step_m = e * radius_m * ripple_scale;
		float ripple_x = (fbm(m + vec2(step_m, 0.0)) - fbm(m - vec2(step_m, 0.0))) * ripple_strength;
		float ripple_y = (fbm(m + vec2(0.0, step_m)) - fbm(m - vec2(0.0, step_m))) * ripple_strength;
		float dx = (film_height(p + vec2(e, 0.0)) - film_height(p - vec2(e, 0.0)) + ripple_x * h) / (2.0 * e * radius_m);
		float dy = (film_height(p + vec2(0.0, e)) - film_height(p - vec2(0.0, e)) + ripple_y * h) / (2.0 * e * radius_m);
		vec3 n = normalize(vec3(-dx * bumpiness, dy * bumpiness, 1.0));
		COLOR = vec4(n * 0.5 + 0.5, 1.0);
	}
}
