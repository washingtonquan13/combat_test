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
//  - Size: none of that suits a canal or a pond, where surf lines and a
//    shallow ring squeezed into a few metres read as noise. shore_tex's
//    green channel says how open the water is; small bodies go still,
//    dark and mirror-like, and only the river and the lake get surf.
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
// Small bodies: their colour, and the openness, in metres of water to the
// nearest bank, over which water turns from still to open. Surf lines and
// the shallow ring need more room again.
uniform vec3 still_color : source_color = vec3(0.13, 0.17, 0.15);
uniform vec2 still_range = vec2(15.0, 120.0);
uniform vec2 surf_range = vec2(150.0, 240.0);

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
float waves(vec2 xz, float t, float pixel, float size) {
	vec2 p = xz / size;
	float freq = 1.0;
	float amp = 1.0;
	float sharp = choppy;
	float h = 0.0;
	float total = 0.0;
	for (int i = 0; i < 4; i++) {
		float keep = 1.0 - smoothstep(0.15, 0.5, pixel * freq / size);
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

	float metres = shallow_reach * 4.0;
	float open = 255.0;
	if (has_shore) {
		vec2 suv = (xz - shore_origin) / shore_size;
		vec2 s = texture(shore_tex, suv).rg * 255.0;
		metres = s.x;
		open = s.y;
	}
	float still = 1.0 - smoothstep(still_range.x, still_range.y, open);
	float surf = smoothstep(surf_range.x, surf_range.y, open);

	// Still water: a fine, low ripple, slower, the wind barely reaching it.
	float size = wave_size * mix(1.0, 0.45, still);
	float tt = t * mix(1.0, 0.4, still);
	float e = max(pixel, size * 0.01);
	float h = waves(xz, tt, pixel, size);
	vec2 grad = vec2(waves(xz + vec2(e, 0.0), tt, pixel, size) - h, waves(xz + vec2(0.0, e), tt, pixel, size) - h) / e;
	float lift = wave_height * mix(1.0, 0.3, still);
	vec3 n = normalize(vec3(-grad.x * lift, 1.0, -grad.y * lift));

	vec3 eye = normalize(world_pos - CAMERA_POSITION_WORLD);
	float facing = clamp(dot(n, -eye), 0.0, 1.0);
	// Seascape's softer cube rather than Schlick's fifth power, so the
	// overhead camera still sees some sky in the water.
	float fresnel = clamp(0.04 + 0.96 * pow(1.0 - facing, 3.0), 0.0, 1.0) * mix(reflect_strength, 1.0, still);
	vec3 r = reflect(eye, n);
	vec3 sky = mix(sky_horizon, sky_zenith, sqrt(clamp(r.y, 0.0, 1.0)));

	// The shallow ring only where there is room for one; a pond is one
	// colour, slightly lighter at its middle rather than its edge.
	vec3 body = mix(deep_color, shallow_color, (1.0 - smoothstep(0.0, shallow_reach, metres)) * surf);
	body = mix(body, still_color, still);
	body = mix(body, body * 1.25, noise(xz / patch_size + TIME * 0.01) * 0.5 + 0.5);
	body += (crest_color - deep_color) * clamp(h - 0.45, 0.0, 1.0) * 0.6 * (1.0 - still);

	// Foam: solid at the bank, then lines rolling in, broken up by noise so
	// each reads as a ragged band rather than a contour.
	float rag = noise(xz / (foam_spacing * units_per_metre) * 0.6 + vec2(t * 0.1, 0.0)) * 0.5 + 0.5;
	float m = metres + rag * foam_spacing * 0.6;
	float line = fract(m / foam_spacing + TIME * foam_speed);
	float lw = fwidth(m / foam_spacing) + 1e-4;
	float band = smoothstep(0.0, lw, line) * (1.0 - smoothstep(0.18 - lw, 0.18, line));
	float lines = band * (1.0 - smoothstep(foam_reach * 0.3, foam_reach, metres)) * step(0.35, rag + h * 0.4) * surf;
	// Small water keeps no foam at all; mid-sized a thin rim.
	float rim = foam_edge * mix(0.35, 1.0, surf);
	float edge = (1.0 - smoothstep(rim * 0.5, rim + rag * rim, metres)) * (1.0 - still);
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
