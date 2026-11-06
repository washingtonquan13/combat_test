// Which of a cloud's cubes are going, for fog_cloud.gd's puff shaders:
// one texel per CloudGrid cube over the cloud's box, 0 while the cube
// holds, rising to 1 as it recedes. Looked up once per puff at its
// centre, so a puff fades whole with its own cube and nothing else does.
uniform sampler3D cube_mask : filter_nearest, repeat_disable;
// World point -> the mask's 0..1 box (fog_cloud.gd keeps it fixed to
// the cubes while the cloud drifts off as it dissipates).
uniform mat4 mask_space = mat4(1.0);

float cube_gone(vec3 world) {
	vec3 uvw = (mask_space * vec4(world, 1.0)).xyz;
	return textureLod(cube_mask, uvw, 0.0).r;
}
