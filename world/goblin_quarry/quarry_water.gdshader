shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_burley, specular_schlick_ggx;

// The stream and the pond. Clear in the shallows, where the bed shows through
// bent by the ripples, darkening with depth; the sky reflects at a grazing look.
// COLOR.rg is the flow direction (0.5 = still), COLOR.b the flow speed over
// flow_max, solved by the bake from the banks and depth: fast in narrows and
// shallows, slow at the banks, near still across the pond. Ripples move with
// the flow by two staggered phases faded into each other, so they never
// stretch where the flow turns, and run choppier where it is fast.

uniform vec3 deep_color : source_color = vec3(0.035, 0.075, 0.06);
uniform vec3 murk_color : source_color = vec3(0.16, 0.2, 0.12);
// Metres of water, looking through it, to turn the bed from seen to unseen.
uniform float clear_depth = 0.55;
uniform float ripple_size = 0.7;
uniform float ripple_height = 0.35;
uniform float refraction = 0.03;
// Metres a second a flow speed of 1 stands for: the bake's FLOW_MAX.
uniform float flow_max = 1.2;
// Seconds each ripple phase is dragged along before it fades and resets.
uniform float flow_cycle = 3.0;
// Ripple height in still water and in water at flow_max.
uniform float chop_still = 0.7;
uniform float chop_fast = 1.8;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

varying vec3 world_pos;
varying vec3 flow;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	flow = vec3(COLOR.rg * 2.0 - 1.0, COLOR.b * flow_max);
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float ripples(vec2 p) {
	float t = TIME * 0.35;
	float h = noise(p + vec2(t, t * 0.6)) * 0.6;
	h += noise(p * 2.3 - vec2(t * 0.8, -t)) * 0.3;
	h += noise(p * 5.1 + vec2(-t * 1.3, t * 0.7)) * 0.1;
	return h;
}

float field(vec2 p) {
	// Two copies dragged along the flow half a cycle apart, each faded out
	// as it resets.
	// Ripple units a second: p is in ripple_size metres.
	vec2 vel = flow.xy * flow.z / ripple_size;
	float ph0 = fract(TIME / flow_cycle);
	float ph1 = fract(TIME / flow_cycle + 0.5);
	float a = ripples(p - vel * ph0 * flow_cycle);
	float b = ripples(p - vel * ph1 * flow_cycle + vec2(3.7, 1.3));
	return mix(a, b, abs(1.0 - 2.0 * ph0));
}

void fragment() {
	vec2 p = world_pos.xz / ripple_size;
	float e = 0.08;
	float h0 = field(p);
	vec2 grad = vec2(field(p + vec2(e, 0.0)) - h0, field(p + vec2(0.0, e)) - h0) / e;
	float chop = ripple_height * mix(chop_still, chop_fast, clamp(flow.z / flow_max, 0.0, 1.0));
	vec3 n_world = normalize(vec3(-grad.x * chop, 1.0, -grad.y * chop));
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	// How much water lies between this surface and the bed behind it.
	float scene = texture(depth_tex, SCREEN_UV).r;
	vec4 behind = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, scene, 1.0);
	behind.xyz /= behind.w;
	float thick = max(0.0, VERTEX.z - behind.z);

	vec2 bent = SCREEN_UV + n_world.xz * refraction * clamp(thick * 2.0, 0.0, 1.0);
	// Only bend toward what is actually behind the water, never what is in front.
	float bent_scene = texture(depth_tex, bent).r;
	vec4 bent_behind = INV_PROJECTION_MATRIX * vec4(bent * 2.0 - 1.0, bent_scene, 1.0);
	bent_behind.xyz /= bent_behind.w;
	if (bent_behind.z > VERTEX.z) {
		bent = SCREEN_UV;
	}
	vec3 bed = texture(screen_tex, bent).rgb;

	float seen = exp(-thick / clear_depth);
	vec3 body = mix(deep_color, murk_color, seen);
	ALBEDO = body * (1.0 - seen);
	EMISSION = bed * seen * mix(vec3(1.0), murk_color * 3.0, 0.35);
	ROUGHNESS = 0.06;
	METALLIC = 0.0;
	SPECULAR = 0.5;
	// The water's edge meets the bank without a line.
	ALPHA = smoothstep(0.0, 0.05, thick);
}
