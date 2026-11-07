// What the Wall of Water's three meshes (water_wall.gd: the wave, the
// curtain falling off its lip, the foam on the ground) share: each is
// built once at full height, and the vertex shader settles it to where
// it stands now. Each vertex carries its station's foot (CUSTOM0.xyz)
// and where along the stations it is (CUSTOM0.w); `heights` holds each
// station's height 0..1 (rising, receding, collapsing), and the vertex
// is pulled down toward the foot and in toward the wall's line to match.
// The crest's height and the lip's reach swell and sink slowly along the
// wall (UV.x is metres along it), so it is never one shape extruded.
// CUSTOM1: x the share of the way along the cross-section, y how thick
// the water is there (metres), z how high up the wave it is (0..1),
// w how far forward toward the lip (0..1).

uniform sampler2D heights : filter_linear, repeat_disable;
uniform float station_count = 1.0;
// The node's up in its own space (it may be turned).
uniform vec3 up_local = vec3(0.0, 1.0, 0.0);
uniform sampler2D streaks : filter_linear_mipmap, repeat_enable;
// Metres a second the water runs along the sheet.
uniform float flow_speed = 2.2;
// The whole wall fading out (dissipate), 1 while it stands.
uniform float strength = 1.0;
// How much the crest's height and the lip's reach vary along the wall.
uniform float crest_swell = 0.09;
uniform float lip_swell = 0.14;

varying float height;
varying float share;
varying float thickness;
varying float rise;

float swell(float x, float t) {
	return sin(x * 0.83 + t * 0.5) * 0.55 + sin(x * 2.1 - t * 0.9 + 1.3) * 0.3 + sin(x * 4.7 + t * 1.7) * 0.15;
}

// Settles VERTEX (full height) to station height h, and its normal with it.
void settle(inout vec3 v, inout vec3 n, vec3 foot, float h, float x, float up_share, float forward) {
	vec3 d = v - foot;
	float dv = dot(d, up_local);
	vec3 dh = d - up_local * dv;
	float lift = h * (1.0 + crest_swell * swell(x, TIME) * up_share);
	float reach = mix(0.35, 1.0, h) * (1.0 + lip_swell * swell(x * 0.7 + 5.0, TIME * 0.8) * forward);
	v = foot + dh * reach + up_local * dv * lift;
	float nv = dot(n, up_local);
	vec3 nh = n - up_local * nv;
	n = normalize(nh / max(reach, 0.05) + up_local * nv / max(lift, 0.05));
}

// Settles the vertex in vertex(), filling the varyings (which a function
// may not assign).
#define SETTLE_VERTEX height = texture(heights, vec2((CUSTOM0.w + 0.5) / station_count, 0.5)).r; share = CUSTOM1.x; thickness = CUSTOM1.y; rise = CUSTOM1.z; settle(VERTEX, NORMAL, CUSTOM0.xyz, height, UV.x, CUSTOM1.z, CUSTOM1.w);
