// Wind for generated trees (tools/quarry/plant_gen.gd). The whole tree sways
// from the ground up; branches bob by their distance from the trunk and their
// own phase (UV2), so bark and the cards on a branch move together.
//
// Direction, strength and gusts are the shared wind (wind.gdshaderinc), the
// one the grass uses: a tree leans the way the grass leans, and a gust front
// reaches a tree when it reaches the grass around it (gusts run on real
// time). The sway itself is slower than grass: `wind_speed` scales its rate
// and the bob's. Amplitudes are per metre of tree at `wind_strength` 0.5 and
// grow with it.
//
// TAA does follow this motion: Godot 4.4 Forward+ writes motion vectors for
// TIME-driven vertex motion (checked with the motion-vector debug draw, grass
// change 2 in docs/plans/bg3_grass_proposal.md). Leaf edges still shimmer
// when they move fast, so speed stays low: at 0.15 the canopy reads near
// still trees while the sway stays visible.
//
// No material sets these today, so a change to a default reaches every tree
// with no re-bake.

#include "res://world/goblin_quarry/wind.gdshaderinc"

uniform float wind_sway = 0.012;
uniform float wind_bob = 0.03;
uniform float wind_speed = 0.15;
uniform float wind_flutter = 0.0;

vec3 tree_wind(vec3 v, vec2 w, float height_t, mat4 model, float time) {
	vec3 origin = model[3].xyz;
	vec3 d = wind_dir_local(model);
	float strength = wind_strength / 0.5;
	float gust = 0.5 + wind_gust(origin.xz, time);
	float sway = gust * (0.45 + 0.55 * wind_wave(origin.xz, time, wind_speed));
	float bend = height_t * height_t * v.y;
	v += d * sway * wind_sway * strength * bend;
	float inst = origin.x * 0.37 + origin.z * 0.21;
	float slow = time * wind_speed;
	float reach = w.x;
	float bob = sin(slow * 1.9 + w.y * 6.283 + inst) + wind_flutter * sin(slow * 3.7 + w.y * 17.0);
	bob *= wind_bob * strength * gust;
	v.y += bob * reach * reach * 0.4;
	v += d * bob * reach * 0.15;
	return v;
}
