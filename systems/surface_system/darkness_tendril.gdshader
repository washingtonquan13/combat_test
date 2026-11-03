// One curl of Darkness's tendrils, drawn on a GPUParticles3D quad: thin
// strands that wind out from the quad's center and taper away, with a
// faint violet glow along their edges. Billboarding, soft-particle depth
// fade and `dissipate` work as in fog_puff.gdshader, so fog_cloud.gd
// drives both layers the same way.
shader_type spatial;
render_mode unshaded, depth_draw_never, cull_disabled, shadows_disabled;

instance uniform vec3 shade_color : source_color = vec3(0.02, 0.015, 0.035);
instance uniform vec3 rim_color : source_color = vec3(0.2, 0.07, 0.32);
instance uniform float opacity = 0.9;
instance uniform float dissipate = 0.0;
uniform float strands = 4.0;
uniform float twist = 1.4;
uniform float softness = 1.2;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear;

varying float seed;

void vertex() {
	mat4 world = mat4(normalize(INV_VIEW_MATRIX[0]), normalize(INV_VIEW_MATRIX[1]), normalize(INV_VIEW_MATRIX[2]), MODEL_MATRIX[3]);
	float a = INSTANCE_CUSTOM.x;
	world = world * mat4(vec4(cos(a), -sin(a), 0.0, 0.0), vec4(sin(a), cos(a), 0.0, 0.0), vec4(0.0, 0.0, 1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_MATRIX = VIEW_MATRIX * world;
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0), vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0), vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	seed = fract(float(INSTANCE_ID) * 0.6180339);
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
	float r = length(centered);
	float angle = atan(centered.y, centered.x) / 6.2831853 + 0.5;
	// Strands: ridges of noise running out along the radius, wound by
	// twist, wavering with a second noise so no two curl alike.
	float waver = fbm(vec2(r * 2.0 - TIME * 0.12, seed * 9.0)) - 0.5;
	vec2 p = vec2(angle * strands + r * twist + waver * 1.4 + seed * 31.0, r * 1.5 - TIME * 0.18);
	float ridge = 1.0 - abs(fbm(p) * 2.0 - 1.0);
	float strand = smoothstep(0.62, 0.92, ridge);
	// Thicker toward the center, tapering out to nothing at the tips.
	float taper = smoothstep(1.0, 0.35, r) * smoothstep(0.0, 0.25, r);
	float shape = strand * taper;
	// A soft dark body under the strands so they read as smoke, not wire.
	shape = max(shape, smoothstep(0.75, 0.0, r) * 0.55 * fbm(centered * 2.0 + seed * 7.0 + TIME * 0.04));

	float d = clamp(dissipate * 1.5 - seed * 0.5, 0.0, 1.0);
	shape *= smoothstep(d - 0.05, d + 0.25, ridge * 0.7 + (1.0 - r) * 0.3) * (1.0 - dissipate);

	float depth = texture(depth_texture, SCREEN_UV).r;
	vec4 scene = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	scene.xyz /= scene.w;
	float soft = clamp((VERTEX.z - scene.z) / softness, 0.0, 1.0);

	// The glow sits on the strands' edges, never in their cores.
	float edge = smoothstep(0.5, 0.7, ridge) * (1.0 - smoothstep(0.8, 0.95, ridge)) * taper;
	ALBEDO = mix(shade_color, rim_color, edge * 0.65) * COLOR.rgb;
	ALPHA = clamp(shape * soft * opacity * COLOR.a, 0.0, 1.0);
}
