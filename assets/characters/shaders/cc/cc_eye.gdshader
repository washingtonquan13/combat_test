shader_type spatial;
// Character Creator RLEye, drawn on the cornea shell (opaque; the eyeball
// under it keeps its imported material and is never seen). Built for Godot
// from the parameters in CC's JSON and what its maps hold.
//
// The cornea's UVs centre the iris at (0.5, 0.5). The iris is a flat disc
// sunk under the cornea's dome: each pixel's view ray is bent at the dome and
// followed down to that disc, and both the iris edge and the texture are read
// where it lands, so the iris stays round from any angle.
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
// The iris itself is matte; the shine over it is the cornea's coat.
uniform float iris_roughness = 1.0;
uniform float iris_specular = 0.2;
// The wet cornea: a near-mirror coat over everything.
uniform float cornea_coat = 0.8;
uniform float cornea_coat_roughness = 0.03;
// Flips the refraction if a mesh's tangents run the other way.
// Depth of the iris below the top of the cornea, in metres.
uniform float iris_depth_m = 0.003;

// Slot 1: slot 0 is the outline pass's outline_color (outline_pass.gdshader).
instance uniform vec3 iris_tint : source_color, instance_index(1) = vec3(1.0);

vec3 unpack_n(vec4 t) {
	vec2 xy = t.xy * 2.0 - 1.0;
	return vec3(xy, sqrt(max(0.0, 1.0 - dot(xy, xy))));
}

void fragment() {
	vec2 d = UV - 0.5;
	float r = length(d);
	// The sclera map is drawn smaller than the cornea's UVs, and the iris
	// shrinks with it.
	float ir = iris_uv_radius * sclera_uv_radius;

	// Refraction: bend the view at the surface, then follow it down through
	// the dome (deepest over the pupil, nothing at the iris edge).
	// Refraction through the cornea. The ray is bent at the surface and
	// followed down to the iris; where it lands is turned into a UV offset
	// with the surface's own UV gradients (from screen derivatives), so the
	// mesh tangents, which are faceted on this mesh, play no part.
	vec3 n = normalize(NORMAL);
	vec3 dp1 = dFdx(VERTEX);
	vec3 dp2 = dFdy(VERTEX);
	vec2 du1 = dFdx(UV);
	vec2 du2 = dFdy(UV);
	vec3 p2 = cross(dp2, n);
	vec3 p1 = cross(n, dp1);
	float det = dot(dp1, p2);
	det = abs(det) < 1e-12 ? 1e-12 : det;
	vec3 grad_u = (p2 * du1.x + p1 * du2.x) / det;
	vec3 grad_v = (p2 * du1.y + p1 * du2.y) / det;
	vec3 bent = refract(-normalize(VIEW), n, 1.0 / ior);
	float depth = iris_depth_scale * iris_depth_m * max(0.0, 1.0 - (r * r) / (ir * ir));
	vec3 travel = bent * depth / max(-dot(bent, n), 0.3);
	vec2 id = d + vec2(dot(grad_u, travel), dot(grad_v, travel));
	float ri = length(id);

	// 1 on the iris, fading out across the limbus (which lies inside ir).
	float iris = 1.0 - smoothstep(ir - limbus_uv_width, ir, ri);

	// Pupil size: remap the radius inside the iris.
	vec2 tid = id;
	if (ri > 0.0001 && ri < ir) {
		tid *= ir * pow(ri / ir, pupil_scale) / ri;
	}
	// CC's "1.0" brightness is three quarters of the painted iris.
	vec3 iris_col = texture(eye_map, 0.5 + tid * 1.02).rgb * iris_color * iris_tint * iris_brightness * 0.75;
	// The limbus ring: the outer part of the iris falls to black.
	float ring = pow(clamp(ri * limbus_dark_scale * 0.9, 0.0, 1.0), 5.0);
	iris_col *= 1.0 - ring;

	vec3 sclera = texture(sclera_map, 0.5 + d / sclera_uv_radius).rgb * sclera_brightness;
	// The lids' warm shadow: starts a little outside the iris and is full
	// well before the rim, so it shows in the open part of the eye.
	float s1 = shadow_radius * sclera_uv_radius;
	float edge = clamp((r - s1 * shadow_hardness) / max(s1 - s1 * shadow_hardness, 0.0001), 0.0, 1.0);
	sclera *= mix(vec3(1.0), corner_color, edge);

	ALBEDO = mix(sclera, iris_col, iris);
	AO = texture(ao_map, UV).r;

	vec3 ns = unpack_n(texture(sclera_normal_map, UV / sclera_normal_uv_scale));
	ns = normalize(mix(ns, vec3(0.0, 0.0, 1.0), sclera_flatten_normal));
	// CC's iris normal map (a dome) is left out: one surface carries both
	// the iris and the cornea's shine, and the dome bent that shine into
	// blotches over the iris.
	NORMAL_MAP = normalize(mix(ns, vec3(0.0, 0.0, 1.0), iris)) * 0.5 + 0.5;

	ROUGHNESS = mix(sclera_roughness, iris_roughness, iris);
	SPECULAR = mix(0.5 * specular_scale, 0.5 * iris_specular, iris);
	CLEARCOAT = cornea_coat;
	CLEARCOAT_ROUGHNESS = cornea_coat_roughness;
}
