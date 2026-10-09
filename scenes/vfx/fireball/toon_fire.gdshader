shader_type spatial;
// Cel-shaded fire (or smoke) for particle quads: each particle is a crisp,
// wobbling blob with a hot inner core, and it burns away by shrinking from
// its edge instead of fading. The particle's colour (the process material's
// color_ramp) is the blob's outer colour; its alpha is how much of the blob
// is left - 1 whole, 0 burnt away - so the ramp's alpha drives the dissolve.
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

// The hot inner band, and how much of the blob it covers.
uniform vec4 core_color : source_color = vec4(1.0, 0.86, 0.4, 1.0);
uniform float core_amount : hint_range(0.0, 1.0) = 1.0;
uniform float core_size : hint_range(0.0, 1.0) = 0.45;
// Brightness of the core and of the outer colour; above 1 blooms.
uniform float core_boost = 1.25;
uniform float rim_boost = 1.0;
// How lumpy the blob's outline is, how fine the lumps are and how fast they
// boil.
uniform float wobble = 0.45;
uniform float wobble_scale = 2.5;
uniform float wobble_speed = 1.5;
// Edge softness: 0 is razor crisp.
uniform float edge = 0.03;

varying float seed;

float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float noise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i + vec3(0, 0, 0)), hash(i + vec3(1, 0, 0)), f.x),
			mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x),
			mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

void vertex() {
	// Billboarded and spun by the particle's angle, as BILLBOARD_PARTICLES does.
	mat4 world = mat4(normalize(INV_VIEW_MATRIX[0]), normalize(INV_VIEW_MATRIX[1]),
		normalize(INV_VIEW_MATRIX[2]), MODEL_MATRIX[3]);
	world = world * mat4(vec4(cos(INSTANCE_CUSTOM.x), -sin(INSTANCE_CUSTOM.x), 0.0, 0.0),
		vec4(sin(INSTANCE_CUSTOM.x), cos(INSTANCE_CUSTOM.x), 0.0, 0.0),
		vec4(0.0, 0.0, 1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_MATRIX = VIEW_MATRIX * world;
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	seed = float(INSTANCE_ID) * 7.31;
}

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float n = noise(vec3(p * wobble_scale, seed + TIME * wobble_speed));
	float shape = 1.0 - length(p) + (n - 0.5) * wobble;
	float cut = 1.0 - COLOR.a;
	float body = smoothstep(cut, cut + edge + 0.001, shape);
	float core_from = cut + (1.0 - cut) * (1.0 - core_size);
	float hot = smoothstep(core_from, core_from + edge + 0.001, shape) * core_amount;
	ALBEDO = mix(COLOR.rgb * rim_boost, core_color.rgb * core_boost, hot);
	ALPHA = body;
}
