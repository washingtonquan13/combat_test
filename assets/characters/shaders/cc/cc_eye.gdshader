shader_type spatial;
// Character Creator RLEye, drawn on the cornea shell (opaque; the eyeball
// under it keeps its imported material and is never seen). Built for Godot
// from the parameters in CC's JSON and what its maps hold.
//
// The cornea's UVs centre the iris at (0.5, 0.5). The iris is drawn
// refracted: its lookup moves against the view by the depth of the dome
// over it, so it sits inside the eye instead of painted on it.
render_mode cull_back;

// The whole eye: iris in the centre, sclera around.
uniform sampler2D eye_map : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D sclera_map : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D sclera_normal_map : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D ao_map : hint_default_white, filter_linear_mipmap;

uniform float iris_uv_radius = 0.16;
uniform float limbus_uv_width = 0.055;
uniform float limbus_dark_scale = 9.0;
uniform float iris_depth_scale = 0.6;
uniform float ior = 1.4;
// Under 1 widens the pupil, over 1 narrows it.
uniform float pupil_scale = 1.0;
uniform vec3 iris_color : source_color = vec3(1.0);
uniform float iris_brightness = 1.0;
uniform float sclera_brightness = 0.65;
uniform float sclera_roughness = 0.2;
uniform float sclera_flatten_normal = 0.9;
uniform float sclera_normal_uv_scale = 0.75;
uniform float sclera_uv_radius = 0.9;
// The lids' shadow on the eye's edge, and its warm tint.
uniform vec3 corner_color : source_color = vec3(1.0, 0.74, 0.7);
uniform float shadow_radius = 0.35;
uniform float shadow_hardness = 0.5;
uniform float specular_scale = 0.8;
// The wet cornea: a near-mirror coat over everything.
uniform float cornea_coat = 0.8;
uniform float cornea_coat_roughness = 0.03;
// Flips the refraction if a mesh's tangents run the other way.
uniform float parallax_sign = 1.0;

instance uniform vec3 iris_tint : source_color = vec3(1.0);

vec3 unpack_n(vec4 t) {
	vec2 xy = t.xy * 2.0 - 1.0;
	return vec3(xy, sqrt(max(0.0, 1.0 - dot(xy, xy))));
}

void fragment() {
	vec2 d = UV - 0.5;
	float r = length(d);
	float ir = iris_uv_radius;
	// 1 inside the iris, fading out across the limbus.
	float iris = 1.0 - smoothstep(ir - limbus_uv_width * 0.5, ir + limbus_uv_width * 0.5, r);

	// Refraction: the view in the surface's own frame, and the dome's depth
	// over this point (deepest at the pupil, none at the limbus).
	vec3 v = vec3(dot(VIEW, TANGENT), dot(VIEW, BINORMAL), dot(VIEW, NORMAL));
	float depth = iris_depth_scale * 0.1 * max(0.0, 1.0 - (r * r) / (ir * ir));
	vec2 off = parallax_sign * -v.xy / max(v.z, 0.25) * depth / ior;
	vec2 id = d + off * iris;
	// Pupil size: remap the radius inside the iris.
	float ri = length(id);
	if (ri > 0.0001 && ri < ir) {
		id *= ir * pow(ri / ir, pupil_scale) / ri;
	}
	vec2 iuv = 0.5 + id;

	vec3 iris_col = texture(eye_map, iuv).rgb * iris_color * iris_tint * iris_brightness;
	// Darker toward the limbus ring.
	iris_col *= 1.0 - clamp(pow(clamp(ri / ir, 0.0, 1.0), limbus_dark_scale), 0.0, 1.0) * 0.6;

	vec3 sclera = texture(sclera_map, 0.5 + d / sclera_uv_radius).rgb * sclera_brightness;
	// The lids shade the eye's rim, warm where the skin bounces into it.
	float edge = smoothstep(0.5 * (1.0 - shadow_radius), 0.5 + 0.5 * (1.0 - shadow_hardness) * shadow_radius, r);
	sclera *= mix(vec3(1.0), corner_color * (1.0 - 0.5 * edge), edge);

	ALBEDO = mix(sclera, iris_col, iris);
	AO = texture(ao_map, UV).r;

	vec3 ns = unpack_n(texture(sclera_normal_map, UV / sclera_normal_uv_scale));
	ns = normalize(mix(ns, vec3(0.0, 0.0, 1.0), sclera_flatten_normal));
	// CC's iris normal map (a dome) is left out: here one surface carries
	// both the iris and the cornea's shine, and the dome bent that shine
	// into dark and bright blotches over the iris. The iris stays smooth.
	NORMAL_MAP = normalize(mix(ns, vec3(0.0, 0.0, 1.0), iris)) * 0.5 + 0.5;

	ROUGHNESS = mix(sclera_roughness, 0.3, iris);
	SPECULAR = 0.5 * specular_scale;
	CLEARCOAT = cornea_coat;
	CLEARCOAT_ROUGHNESS = cornea_coat_roughness;
}
