class_name SurfaceStepEffect
extends AbilityEffect
## Puddle Step's move: the caster sinks into the surface it stands in and
## rises out of the one aimed at (SurfaceStepTargeting). Nothing crosses
## the ground in between, so walls, units and gaps don't matter and no
## move is spent by distance; the ability's move_cost is the whole toll.
##
## Only the CharacterModel sinks and rises; the unit itself goes straight
## from one spot to the other, so it's never anywhere in between.

## How far the model goes down, metres: the whole body.
@export var depth: float = 2.0
## Seconds to sink, and again to rise.
@export var sink_time: float = 0.45
## Seconds under, between.
@export var under_time: float = 0.15
@export var splash_color: Color = Color(0.65, 0.85, 0.95, 0.9)


func apply(attacker: Unit, target, ability: Ability, _is_critical: bool) -> Dictionary:
	if not target is Vector3:
		return {}
	var destination: Vector3 = target
	var clearance: float = attacker.radius + attacker.avoidance_margin
	var snap: Dictionary = NavigationGrid.nearest_valid_point(attacker.get_tree(), destination, clearance, false, attacker)
	if snap.found:
		destination = snap.point
	var model: Node3D = attacker.get_node_or_null("CharacterModel")
	var rest: Vector3 = model.position if model else Vector3.ZERO
	var down := Vector3(0, depth, 0)

	attacker.begin_busy()
	# Under the floor on purpose: no x-ray silhouette showing it there.
	attacker.add_to_group(XRaySilhouettes.UNDER_GROUND)
	XRaySilhouettes.refresh_all(attacker.get_tree())
	_splash(attacker, attacker.global_position)
	var tween: Tween = attacker.create_tween()
	if model:
		tween.tween_property(model, "position", rest - down, sink_time).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_interval(under_time)
	tween.tween_callback(func() -> void:
		attacker.global_position = destination
		_splash(attacker, destination))
	if model:
		tween.tween_property(model, "position", rest, sink_time).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func() -> void:
		attacker.remove_from_group(XRaySilhouettes.UNDER_GROUND)
		attacker.end_busy())
	return {"stepped_distance": attacker.global_position.distance_to(destination)}


## A ring of droplets thrown up at point.
func _splash(attacker: Unit, point: Vector3) -> void:
	var drops := CPUParticles3D.new()
	drops.one_shot = true
	drops.explosiveness = 0.9
	drops.amount = 40
	drops.lifetime = 0.8
	drops.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	drops.emission_ring_axis = Vector3.UP
	drops.emission_ring_radius = 0.35
	drops.emission_ring_inner_radius = 0.2
	drops.emission_ring_height = 0.0
	drops.direction = Vector3.UP
	drops.spread = 30.0
	drops.initial_velocity_min = 2.0
	drops.initial_velocity_max = 3.5
	drops.gravity = Vector3(0, -9.8, 0)
	drops.scale_amount_min = 0.5
	drops.scale_amount_max = 1.0
	var mesh := SphereMesh.new()
	mesh.radius = 0.04
	mesh.height = 0.08
	mesh.radial_segments = 6
	mesh.rings = 3
	var material := StandardMaterial3D.new()
	material.albedo_color = splash_color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.emission_enabled = true
	material.emission = splash_color * 0.3
	mesh.material = material
	drops.mesh = mesh
	attacker.get_parent().add_child(drops)
	drops.global_position = point + Vector3(0, 0.05, 0)
	drops.emitting = true
	drops.finished.connect(drops.queue_free)


func describe() -> String:
	return "Sink into the surface, rise out of another"
