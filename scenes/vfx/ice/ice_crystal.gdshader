shader_type spatial;
// Ice crystals (ice_crystals.gd). Glassy: the scene behind shows through,
// bent by the facets and tinted cold blue, with a bright rim where the
// facets turn away and a cold glow that strengthens toward each tip.
// Frosted white and rough at the root, where it froze onto the surface.
// The facets are lit for real, so they catch the light as they turn.
//
// Per vertex (from ice_crystals.gd):
//   CUSTOM0.xyz  the crystal's root, which it grows out of
//   CUSTOM0.w    when it starts growing, in seconds
//   UV.x         how far along the crystal, 0 at the root, 1 at the tip
//   UV.y         a random 0..1 per crystal
render_mode blend_mix, depth_draw_always, cull_back, specular_schlick_ggx;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
// Frost and shatter patterns.
uniform sampler2D noise : filter_linear_mipmap, repeat_enable;
// The clock the crystals grow by, and how long each takes to grow.
uniform float time = 0.0;
uniform float grow_seconds = 0.16;
// 0..1: the crystals break up and vanish, not all at once.
uniform float shatter = 0.0;
// How the scene behind is tinted, and how much it is bent.
uniform vec3 tint : source_color = vec3(0.55, 0.8, 1.0);
uniform float refraction = 0.05;
uniform vec3 rim_color : source_color = vec3(0.75, 0.92, 1.0);
uniform float rim_strength = 1.2;
uniform vec3 glow_color : source_color = vec3(0.3, 0.7, 1.0);
uniform float glow_strength = 0.5;
uniform vec3 frost_color : source_color = vec3(0.85, 0.93, 1.0);

varying float along;
varying float crystal_random;
varying vec3 local_position;

void vertex() {
	vec3 root = CUSTOM0.xyz;
	float grow = clamp((time - CUSTOM0.w) / grow_seconds, 0.0, 1.0);
	// Shoots out a little past full size and settles back.
	float c = 1.7;
	float g = grow - 1.0;
	grow = grow > 0.0 ? 1.0 + (c + 1.0) * g * g * g + c * g * g : 0.0;
	local_position = VERTEX;
	VERTEX = root + (VERTEX - root) * grow;
	along = UV.x;
	crystal_random = UV.y;
}

void fragment() {
	float n = texture(noise, local_position.xz * 0.6 + local_position.y * 0.35 + crystal_random).r;
	// Shattering: each crystal goes at its own moment, eaten by the noise,
	// with a bright edge where it is breaking.
	float gone = clamp(shatter * 1.8 - crystal_random * 0.8, 0.0, 1.0);
	if (n < gone) {
		discard;
	}
	float edge = gone > 0.0 ? smoothstep(gone + 0.08, gone, n) : 0.0;
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float rim = pow(1.0 - facing, 3.0);
	vec2 bent = SCREEN_UV + NORMAL.xy * refraction * (0.4 + facing);
	vec3 behind = textureLod(screen_texture, bent, 1.5).rgb;
	float frost = smoothstep(0.3, 0.0, along + (n - 0.5) * 0.25);
	ALBEDO = mix(vec3(0.02, 0.05, 0.08), frost_color * 0.6, frost);
	ROUGHNESS = mix(0.04, 0.55, frost);
	SPECULAR = 0.8;
	METALLIC = 0.0;
	EMISSION = behind * tint * (1.0 - frost * 0.7)
		+ rim_color * rim * rim_strength
		+ glow_color * glow_strength * along * along
		+ rim_color * edge * 3.0;
}
