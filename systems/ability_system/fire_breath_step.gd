class_name FireBreathStep
extends VfxStep
## Breathes a gust of fire (fire_breath.tscn) down the ability's cone,
## from the caster's chest along its aim, landing the cast as it leaves
## the mouth (notify_impact: the damage, and the ground, which catches as
## the front reaches it - SpawnSurfaceEffect.front_seconds), and returns
## once it has burnt out. The caster's head looks down the cone, up or
## down with its aim, while it breathes.

@export var scene: PackedScene = preload("res://systems/surface_system/fire_breath.tscn")
## Seconds the head takes to go back to the animation once it is done.
@export var gaze_release_seconds: float = 0.3


func play(context: Node, _from: Vector3, to: Vector3, ability: Ability = null, caster: Unit = null) -> void:
	if not scene or not ability or not is_instance_valid(caster):
		return
	var cone := ability.targeting as ConeTargeting
	if not cone:
		return
	var apex: Vector3 = cone.origin(caster)
	var along: Vector3 = cone.direction(caster, to)
	var gust: Node3D = scene.instantiate()
	context.add_child(gust)
	gust.breathe(apex, along, cone.length, cone.half_angle())
	caster.notify_impact()
	var gaze := Node3D.new()
	context.add_child(gaze)
	gaze.global_position = apex + along * cone.length
	var gazing: bool = caster.gaze_at(gaze)
	await gust.burnt_out
	if gazing and is_instance_valid(caster):
		caster.stop_gazing(gaze_release_seconds)
	# Kept until the head has eased off it: the modifier still reads it.
	gaze.get_tree().create_timer(gaze_release_seconds + 0.1).timeout.connect(gaze.queue_free)


func describe() -> String:
	return "Breathes fire down the cone, until it burns out"
