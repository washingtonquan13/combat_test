// The city overworld's water. Opaque, lit by the scene's sun through a
// custom light().
//  - Waves: choppy octaves in the manner of TDM's "Seascape": each octave
//    is a domain-warped grid of sharpened sine crests, rotated and scaled
//    against the last, two copies drifting in opposite directions. Octaves
//    smaller than a pixel fade out instead of shimmering.
//  - Colour: Schlick-style fresnel between the water body and the sky the
//    environment shows, crests lit a little brighter, a tight sun highlight
//    for the sparkle.
//  - Shore: the toon-water trick (Roystan, Wind Waker) of shallow colour
//    and foam near the bank, with foam lines rolling in. It usually reads
//    the depth buffer; here it reads shore_tex, metres to the nearest bank
//    baked by tools/blockout/shore_field.py.
shader_type spatial;
render_mode cull_back;

uniform vec3 deep_color : source_color = vec3(0.07, 0.15, 0.20);
uniform vec3 shallow_color : source_color = vec3(0.20, 0.33, 0.33);
// How far from the bank, in metres, the water reaches its deep colour.
uniform float shallow_reach = 60.0;
uniform vec3 crest_color : source_color = vec3(0.30, 0.42, 0.42);
uniform vec3 sky_horizon : source_color = vec3(0.72, 0.76, 0.80);
uniform vec3 sky_zenith : source_color = vec3(0.52, 0.62, 0.74);
uniform float reflect_strength : hint_range(0.0, 1.0) = 0.8;
// World units across one patch of slow colour drift.
uniform float patch_size = 120.0;
// World units across the largest wave, how high the waves stand against
// that size, and how sharp their crests are.
uniform float wave_size = 2.5;
uniform float wave_height = 0.09;
uniform float choppy = 4.0;
uniform vec2 flow = vec2(0.5, 0.2);
uniform float flow_speed = 0.6;
uniform float sun_shine : hint_range(16.0, 2048.0) = 600.0;
uniform float sun_strength = 3.0;
uniform vec3 foam_color : source_color = vec3(0.86, 0.89, 0.90);
// Metres of solid foam at the bank, metres between rolling foam lines,
// and how far out, in metres, the lines reach.
uniform float foam_edge = 6.0;
uniform float foam_spacing = 14.0;
uniform float foam_reach = 40.0;
uniform float foam_speed = 0.35;

uniform sampler2D shore_tex : filter_linear_mipmap, repeat_disable, hint_default_black;
// Where shore_tex lies, in world units, and world units per metre.
uniform vec2 shore_origin = vec2(0.0);
uniform vec2 shore_size = vec2(1.0);
uniform float units_per_metre = 0.25;
uniform bool has_shore = false;

const mat2 OCTAVE_TURN = mat2(vec2(1.6, 1.2), vec2(-1.2, 1.6));

varying vec3 world_pos;
varying float foam_cover;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y) * 2.0 - 1.0;
}

// One octave: a grid of crests, warped so it never reads as a grid. Where
// both sine terms peak the surface rises to a sharp ridge.
float crests(vec2 p, float sharp) {
	p += noise(p);
	vec2 peak = 1.0 - abs(sin(p));
	vec2 trough = abs(cos(p));
	peak = mix(peak, trough, peak);
	return pow(1.0 - pow(peak.x * peak.y, 0.65), sharp);
}

// Height in units of wave_height, 0 to about 1. pixel is world units per
// screen pixel; an octave fades out as its waves near that size.
float waves(vec2 xz, float t, float pixel) {
	vec2 p = xz / wave_size;
	float freq = 1.0;
	float amp = 1.0;
	float sharp = choppy;
	float h = 0.0;
	float total = 0.0;
	for (int i = 0; i < 4; i++) {
		float keep = 1.0 - smoothstep(0.15, 0.5, pixel * freq / wave_size);
		vec2 q = p * freq;
		float d = crests(q + flow * t, sharp) + crests(q - flow.yx * t * 0.8, sharp);
		h += d * 0.5 * amp * keep;
		total += amp;
		p = OCTAVE_TURN * p;
		freq *= 1.9;
		amp *= 0.22;
		sharp = mix(sharp, 1.0, 0.2);
	}
	return h / total;
}

void fragment() {
	vec2 xz = world_pos.xz;
	float t = TIME * flow_speed;
	float pixel = max(length(fwidth(xz)), 1e-4);
	float e = max(pixel, wave_size * 0.01);
	float h = waves(xz, t, pixel);
	vec2 grad = vec2(waves(xz + vec2(e, 0.0), t, pixel) - h, waves(xz + vec2(0.0, e), t, pixel) - h) / e;
	vec3 n = normalize(vec3(-grad.x * wave_height, 1.0, -grad.y * wave_height));

	vec3 eye = normalize(world_pos - CAMERA_POSITION_WORLD);
	float facing = clamp(dot(n, -eye), 0.0, 1.0);
	// Seascape's softer cube rather than Schlick's fifth power, so the
	// overhead camera still sees some sky in the water.
	float fresnel = clamp(0.04 + 0.96 * pow(1.0 - facing, 3.0), 0.0, 1.0) * reflect_strength;
	vec3 r = reflect(eye, n);
	vec3 sky = mix(sky_horizon, sky_zenith, sqrt(clamp(r.y, 0.0, 1.0)));

	float metres = shallow_reach * 4.0;
	if (has_shore) {
		vec2 suv = (xz - shore_origin) / shore_size;
		metres = texture(shore_tex, suv).r * 255.0;
	}
	vec3 body = mix(shallow_color, deep_color, smoothstep(0.0, shallow_reach, metres));
	body = mix(body, body * 1.25, noise(xz / patch_size + TIME * 0.01) * 0.5 + 0.5);
	body += (crest_color - deep_color) * clamp(h - 0.45, 0.0, 1.0) * 0.6;

	// Foam: solid at the bank, then lines rolling in, broken up by noise so
	// each reads as a ragged band rather than a contour.
	float rag = noise(xz / (foam_spacing * units_per_metre) * 0.6 + vec2(t * 0.1, 0.0)) * 0.5 + 0.5;
	float m = metres + rag * foam_spacing * 0.6;
	float line = fract(m / foam_spacing + TIME * foam_speed);
	float lw = fwidth(m / foam_spacing) + 1e-4;
	float band = smoothstep(0.0, lw, line) * (1.0 - smoothstep(0.18 - lw, 0.18, line));
	float lines = band * (1.0 - smoothstep(foam_reach * 0.3, foam_reach, metres)) * step(0.35, rag + h * 0.4);
	float edge = 1.0 - smoothstep(foam_edge * 0.5, foam_edge + rag * foam_edge, metres);
	foam_cover = has_shore ? clamp(max(edge, lines * 0.8), 0.0, 1.0) : 0.0;

	// The reflection is emitted, not lit, so at grazing angles the water
	// meets the haze at exactly the colour the environment shows.
	ALBEDO = mix(body * (1.0 - fresnel), foam_color, foam_cover);
	EMISSION = sky * fresnel * (1.0 - foam_cover);
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

void light() {
	float lit = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	// The water body barely shades by angle; foam is a matte surface.
	float wrap = mix(0.6 + 0.4 * lit, lit, foam_cover);
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * wrap / PI;
	vec3 half_dir = normalize(LIGHT + VIEW);
	float spec = pow(clamp(dot(NORMAL, half_dir), 0.0, 1.0), sun_shine);
	spec *= (sun_shine + 8.0) / (8.0 * PI);
	SPECULAR_LIGHT += LIGHT_COLOR * ATTENUATION * spec * sun_strength * 0.02 * (1.0 - foam_cover);
}
