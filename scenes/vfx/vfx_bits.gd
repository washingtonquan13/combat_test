class_name VfxBits
## Small pieces the code-built spell visuals share (magic_missile_projectile,
## fire_bolt_projectile, frost_ray): a soft additive glow, a one-shot
## particle burst, and a flash that swells and fades. Each piece frees
## itself when it is done, so a caller can spawn it and forget it.

## A soft round additive glow on a camera-facing quad. Bright past 1 so
## the environment's glow blooms it. Particles' color_ramp multiplies it.
const GLOW_SHADER_CODE := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
uniform vec4 tint : source_color = vec4(1.0);
uniform float energy = 3.0;
uniform float hardness = 2.0;
void vertex() {
	float s = length(MODEL_MATRIX[0].xyz);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0] * s, INV_VIEW_MATRIX[1] * s, INV_VIEW_MATRIX[2] * s, MODEL_MATRIX[3]);
}
void fragment() {
	float d = length(UV * 2.0 - 1.0);
	float a = pow(clamp(1.0 - d, 0.0, 1.0), hardness);
	ALBEDO = tint.rgb * COLOR.rgb * energy;
	ALPHA = clamp(a * tint.a * COLOR.a, 0.0, 1.0);
}
"""

static var _glow_shader: Shader


static func glow_material(color: Color, energy: float, hardness: float = 2.0) -> ShaderMaterial:
	if _glow_shader == null:
		_glow_shader = Shader.new()
		_glow_shader.code = GLOW_SHADER_CODE
	var material := ShaderMaterial.new()
	material.shader = _glow_shader
	material.set_shader_parameter(&"tint", color)
	material.set_shader_parameter(&"energy", energy)
	material.set_shader_parameter(&"hardness", hardness)
	return material


## A glow quad `size` metres across, as a child of parent.
static func glow(parent: Node3D, color: Color, size: float, energy: float, hardness: float = 2.0) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	var instance := MeshInstance3D.new()
	instance.mesh = quad
	instance.material_override = glow_material(color, energy, hardness)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)
	return instance


## A colour ramp from `colors`, evenly spaced, for a particle's lifetime.
static func ramp(colors: PackedColorArray) -> GradientTexture1D:
	var gradient := Gradient.new()
	var offsets := PackedFloat32Array()
	for i in colors.size():
		offsets.append(float(i) / max(colors.size() - 1, 1))
	gradient.offsets = offsets
	gradient.colors = colors
	var texture := GradientTexture1D.new()
	texture.gradient = gradient
	return texture


## A size curve for a particle's lifetime, from `start` to `end` times
## its scale.
static func size_curve(start: float, end: float) -> CurveTexture:
	var curve := Curve.new()
	curve.max_value = max(start, end, 1.0)
	curve.add_point(Vector2(0.0, start))
	curve.add_point(Vector2(1.0, end))
	var texture := CurveTexture.new()
	texture.curve = curve
	return texture


## Particles of glow quads, `size` metres across, in world space. Not
## emitting yet: set emitting, or one_shot and emitting, after.
static func particles(parent: Node3D, color: Color, size: float, energy: float, amount: int, lifetime: float) -> GPUParticles3D:
	var emitter := GPUParticles3D.new()
	emitter.amount = amount
	emitter.lifetime = lifetime
	emitter.local_coords = false
	emitter.emitting = false
	emitter.visibility_aabb = AABB(Vector3(-10, -10, -10), Vector3(20, 20, 20))
	emitter.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	quad.material = glow_material(color, energy)
	emitter.draw_pass_1 = quad
	var process := ParticleProcessMaterial.new()
	process.gravity = Vector3.ZERO
	emitter.process_material = process
	parent.add_child(emitter)
	return emitter


## One burst of `amount` sparks thrown out in every direction from
## `at`, slowed by damping and pulled by gravity. Frees itself.
static func burst(at: Vector3, color: PackedColorArray, size: float, energy: float, amount: int,
		lifetime: float, speed: Vector2, gravity: float = 0.0, damping: float = 4.0) -> GPUParticles3D:
	var holder := Node3D.new()
	WorldManager.spawn_parent().add_child(holder)
	holder.global_position = at
	var emitter := particles(holder, Color.WHITE, size, energy, amount, lifetime)
	emitter.one_shot = true
	emitter.explosiveness = 1.0
	var process := emitter.process_material as ParticleProcessMaterial
	process.direction = Vector3.UP
	process.spread = 180.0
	process.initial_velocity_min = speed.x
	process.initial_velocity_max = speed.y
	process.gravity = Vector3(0.0, gravity, 0.0)
	process.damping_min = damping
	process.damping_max = damping
	process.scale_min = 0.6
	process.scale_max = 1.3
	process.scale_curve = size_curve(1.0, 0.2)
	process.color_ramp = ramp(color)
	emitter.emitting = true
	_free_after(holder, lifetime + 0.2)
	return emitter


## A glow that swells from nothing to `size` and fades over `time`.
## Frees itself.
static func flash(at: Vector3, color: Color, size: float, energy: float, time: float) -> void:
	var holder := Node3D.new()
	WorldManager.spawn_parent().add_child(holder)
	holder.global_position = at
	var quad := glow(holder, color, 1.0, energy, 1.6)
	quad.scale = Vector3.ONE * size * 0.3
	var material := quad.material_override as ShaderMaterial
	var tween := holder.create_tween().set_parallel()
	tween.tween_property(quad, "scale", Vector3.ONE * size, time).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.tween_method(func(e: float): material.set_shader_parameter(&"energy", e), energy, 0.0, time)
	tween.chain().tween_callback(holder.queue_free)


## A light that flares to `energy` and dies out over `time`. Frees itself.
static func light_flash(at: Vector3, color: Color, energy: float, light_range: float, time: float) -> void:
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = energy
	light.omni_range = light_range
	light.shadow_enabled = false
	WorldManager.spawn_parent().add_child(light)
	light.global_position = at
	var tween := light.create_tween()
	tween.tween_property(light, "light_energy", 0.0, time).set_ease(Tween.EASE_OUT)
	tween.tween_callback(light.queue_free)


static func _free_after(node: Node, seconds: float) -> void:
	node.get_tree().create_timer(seconds).timeout.connect(func():
		if is_instance_valid(node):
			node.queue_free())
