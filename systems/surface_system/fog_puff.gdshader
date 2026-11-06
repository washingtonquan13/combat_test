// One soft smoke puff, drawn on a GPUParticles3D quad. Faces the camera
// but keeps the emitter's scale (fog_cloud.gd grows it as it dissipates),
// turns by the particle's angle, and fades where it meets the
// floor or a unit (soft particles) so it never shows a hard cut line.
// The puff itself is procedural noise, no texture. `dissipate` (0 to 1,
// set per cloud by fog_cloud.gd) eats each puff from its thin edges
// inward, so the cloud breaks into wisps instead of fading evenly; a
// receding cube (cloud_mask.gdshaderinc) eats just its own puffs the same way.
shader_type spatial;
render_mode unshaded, depth_draw_never, cull_disabled, shadows_disabled;
#include "res://systems/surface_system/cloud_mask.gdshaderinc"

instance uniform vec3 lit_color : source_color = vec3(0.86, 0.88, 0.9);
instance uniform vec3 shade_color : source_color = vec3(0.52, 0.56, 0.62);
instance uniform float opacity = 0.6;
uniform float softness = 1.2;
instance uniform float dissipate = 0.0;
// Charge (Electrified Steam): the cloud flickers, and now and then a puff
// flashes blue-white. 0 for a plain cloud.
instance uniform float flicker = 0.0;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear;

varying float seed;
varying float gone;

void vertex() {
	mat4 world = mat4(normalize(INV_VIEW_MATRIX[0]), normalize(INV_VIEW_MATRIX[1]), normalize(INV_VIEW_MATRIX[2]), MODEL_MATRIX[3]);
	float a = INSTANCE_CUSTOM.x;
	world = world * mat4(vec4(cos(a), -sin(a), 0.0, 0.0), vec4(sin(a), cos(a), 0.0, 0.0), vec4(0.0, 0.0, 1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_MATRIX = VIEW_MATRIX * world;
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0), vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0), vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	seed = fract(float(INSTANCE_ID) * 0.6180339);
	gone = cube_gone(MODEL_MATRIX[3].xyz);
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

float fbm(vec2 p) {
	float total = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; i++) {
		total += noise(p) * amp;
		p *= 2.03;
		amp *= 0.5;
	}
	return total;
}

void fragment() {
	vec2 centered = UV * 2.0 - 1.0;
	float n = fbm(UV * 3.0 + seed * 17.0 + vec2(TIME * 0.05, 0.0));
	// Lumpy edge: the noise eats into a round falloff.
	float shape = smoothstep(1.0, 0.25, length(centered) + (n - 0.5) * 0.7);
	// Thin parts go first: the edge and the noise's low spots. Each puff
	// starts a little later than the last, so the cloud breaks up rather
	// than thinning in lockstep, and the whole cloud fades with it.
	// The whole cloud thinning away, or just this puff's cube receding.
	float fade = max(dissipate, gone);
	float d = clamp(fade * 1.5 - seed * 0.5, 0.0, 1.0);
	float cut = mix(-0.25, 1.0, d);
	shape *= smoothstep(cut - 0.25, cut + 0.1, shape * 0.4 + n * 0.6) * (1.0 - fade);

	float depth = texture(depth_texture, SCREEN_UV).r;
	vec4 scene = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	scene.xyz /= scene.w;
	float soft = clamp((VERTEX.z - scene.z) / softness, 0.0, 1.0);

	// Lighter on top, as if lit from above.
	float light = clamp(0.5 - centered.y * 0.45 + (n - 0.5) * 0.6, 0.0, 1.0);
	ALBEDO = mix(shade_color, lit_color, light) * COLOR.rgb;
	if (flicker > 0.0) {
		float shimmer = noise(vec2(TIME * 9.0, seed * 13.0)) - 0.5;
		float flash = step(0.94, hash(vec2(floor(TIME * 14.0), seed * 91.0)));
		ALBEDO *= 1.0 + flicker * 0.3 * shimmer;
		ALBEDO = mix(ALBEDO, vec3(0.85, 0.93, 1.0) * 1.6, flash * flicker * shape);
	}
	ALPHA = shape * soft * opacity * COLOR.a;
}
