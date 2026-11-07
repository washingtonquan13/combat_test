shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, specular_schlick_ggx;

// The Wall of Water's one sheet (water_wall.gd): a breaking wave held at
// its peak. UV.x runs along the wall in metres, UV.y along the sheet's
// cross-section in metres from the back foot, up over the crest, round
// the lip, back under it and down the face to the front foot, so water
// scrolling in +UV.y climbs the back, pours over the lip and falls down
// the face, forever. UV2.x is the same cross-section 0..1 (where the
// crest, lip and feet are); UV2.y the station's height 0..1 as it rises,
// recedes or collapses. What's behind shows through, bent.
// `crackle` (Electrified Wall of Water) runs a Voronoi web of lightning
// through the water, the electrified ground's look.

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D streaks : filter_linear_mipmap, repeat_enable;
uniform vec3 deep_color : source_color = vec3(0.02, 0.17, 0.24);
uniform vec3 shallow_color : source_color = vec3(0.12, 0.45, 0.52);
uniform vec3 foam_color : source_color = vec3(0.88, 0.95, 0.97);
// Metres a second the water runs along the sheet.
uniform float flow_speed = 2.2;
// How far it bends what's behind, as a fraction of the screen.
uniform float refraction = 0.03;
uniform float ripple = 0.05;
// The whole wall fading out (dissipate), 1 while it stands.
uniform float strength = 1.0;
uniform float crackle = 0.0;
uniform vec3 crackle_color : source_color = vec3(0.45, 0.7, 1.0);
uniform float crackle_energy = 6.0;

varying float profile;
varying float height;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

vec2 hash2(vec2 p) {
	return vec2(hash(p), hash(p + vec2(17.3, 41.9)));
}

// Distance to the nearest edge between Voronoi cells: thin bright lines
// where it is near 0.
float voronoi_edge(vec2 p, float t) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 nearest = vec2(8.0);
	vec2 cell = vec2(0.0);
	float best = 8.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 g = vec2(float(x), float(y));
			vec2 o = 0.5 + 0.5 * sin(t + 6.2831 * hash2(i + g));
			vec2 r = g + o - f;
			float d = dot(r, r);
			if (d < best) {
				best = d;
				nearest = r;
				cell = g;
			}
		}
	}
	float edge = 8.0;
	for (int y = -2; y <= 2; y++) {
		for (int x = -2; x <= 2; x++) {
			vec2 g = cell + vec2(float(x), float(y));
			vec2 o = 0.5 + 0.5 * sin(t + 6.2831 * hash2(i + g));
			vec2 r = g + o - f;
			if (dot(nearest - r, nearest - r) > 0.00001) {
				edge = min(edge, dot(0.5 * (nearest + r), normalize(r - nearest)));
			}
		}
	}
	return edge;
}

void vertex() {
	profile = UV2.x;
	height = UV2.y;
	// Small running ripples, out along the sheet's normal; none at the
	// feet, which sit on the ground.
	float feet = smoothstep(0.0, 0.08, profile) * smoothstep(1.0, 0.92, profile);
	float wave = sin(UV.x * 3.1 + TIME * 1.7) * 0.5 + sin(UV.y * 4.3 - TIME * flow_speed * 2.4 + UV.x * 1.3) * 0.5;
	VERTEX += NORMAL * wave * ripple * feet * height;
}

void fragment() {
	vec2 flow = vec2(UV.x * 0.35, UV.y * 0.25 - TIME * flow_speed * 0.25);
	float a = texture(streaks, flow).r;
	float b = texture(streaks, flow * vec2(1.7, 0.6) + vec2(0.37, -TIME * flow_speed * 0.12)).r;
	float run = a * 0.6 + b * 0.4;

	// Foam: thick on the crest and round the lip, churning at both feet,
	// and in streaks running down the face.
	float crest = smoothstep(0.36, 0.46, profile) * smoothstep(0.62, 0.52, profile);
	float feet = smoothstep(0.05, 0.0, profile) + smoothstep(0.95, 1.0, profile);
	float face = smoothstep(0.6, 0.9, profile);
	float foam = crest * smoothstep(0.5, 0.68, run) + feet * smoothstep(0.42, 0.62, run) + face * smoothstep(0.62, 0.74, run) * 0.5;
	foam = clamp(foam, 0.0, 1.0);

	float facing = abs(dot(NORMAL, VIEW));
	float fresnel = pow(1.0 - facing, 3.0);
	// Thin and green-lit near the crest, deep at the base.
	float lit = smoothstep(0.1, 0.45, profile) * smoothstep(0.75, 0.5, profile);
	vec3 water = mix(deep_color, shallow_color, lit * 0.8 + run * 0.2);

	vec2 bend = (vec2(run, b) - 0.5) * refraction * (0.4 + height * 0.6);
	vec3 behind = textureLod(screen_texture, SCREEN_UV + bend, 0.0).rgb;

	ALBEDO = mix(water * 0.7, foam_color, foam);
	ROUGHNESS = mix(0.08, 0.7, foam);
	SPECULAR = 0.4;
	// What's behind, tinted by the water, and light through the thin
	// water near the crest: the sheet is mostly see-through where it is
	// thin, more solid at a grazing angle and in the foam.
	vec3 tint = vec3(0.25, 0.7, 0.8);
	EMISSION = (behind * tint * 0.6 + shallow_color * lit * 0.35) * (1.0 - foam) * (1.0 - fresnel * 0.6);
	float alpha = mix(0.6, 0.95, max(fresnel, foam));

	if (crackle > 0.0) {
		// Only patches of the wall carry a charge at a time, wandering.
		vec2 p = UV * 0.8;
		float patch = smoothstep(0.55, 0.7, texture(streaks, UV * 0.08 + vec2(TIME * 0.05, -TIME * 0.11)).r);
		float flick = step(0.3, hash(floor(vec2(TIME * 14.0, floor(p.x * 0.7)))));
		float e = voronoi_edge(p + vec2(0.0, -TIME * flow_speed * 0.3), TIME * 2.0);
		float line = smoothstep(0.035, 0.0, e) * patch * (0.3 + 0.7 * flick);
		EMISSION += crackle_color * crackle_energy * line * crackle;
		alpha = max(alpha, line * crackle);
	}
	ALPHA = alpha * strength * smoothstep(0.0, 0.15, height);
}
