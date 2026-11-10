// Wind for generated trees (tools/quarry/plant_gen.gd). The whole tree sways
// from the ground up; branches bob by their distance from the trunk and their
// own phase (UV2), so bark and the cards on a branch move together.
// TAA cannot follow this displacement (the motion vectors do not see it), so
// leaf edges shimmer in proportion to how far they move per frame. Speed is
// the cheap lever: at 0.15 the canopy shimmer is near that of still trees
// while the sway stays visible; amplitude cuts it less for the same cost.
// The bake stores these values in each material, so a change here needs a
// re-bake to reach the level.

uniform vec2 wind_dir = vec2(0.8, 0.6);
uniform float wind_sway = 0.012;
uniform float wind_bob = 0.03;
uniform float wind_speed = 0.15;
uniform float wind_flutter = 0.0;

vec3 tree_wind(vec3 v, vec2 w, float height_t, vec3 origin, float time) {
	time *= wind_speed;
	float inst = origin.x * 0.37 + origin.z * 0.21;
	float gust = 0.6 + 0.4 * sin(time * 0.23 + inst * 0.3);
	float sway = (sin(time * 0.9 + inst) * 0.6 + 0.5) * gust;
	vec2 d = normalize(wind_dir);
	float bend = height_t * height_t * v.y;
	v.xz += d * sway * wind_sway * bend;
	float reach = w.x;
	float bob = sin(time * 1.9 + w.y * 6.283 + inst) + wind_flutter * sin(time * 3.7 + w.y * 17.0);
	v.y += bob * wind_bob * gust * reach * reach * 0.4;
	v.xz += d * bob * wind_bob * gust * reach * 0.15;
	return v;
}
