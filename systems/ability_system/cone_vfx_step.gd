class_name ConeVfxStep
extends VfxStep
## Plays a cone blast (frost_cone.tscn, lightning_cone.tscn: any scene
## whose root has play(direction, length, half_angle, targets) and frees
## itself when done) down the ability's cone, from the caster's chest
## along its aim, with the chests of the units the cone catches as its
## targets. It lands the cast as the blast leaves the hand (notify_impact:
## the damage, and any surface, whose SpawnSurfaceEffect.front_seconds
## should match the blast's spread), and returns once the blast is gone.
## The caster's head looks down the cone while it plays.

@export var scene: PackedScene
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
	var targets := PackedVector3Array()
	for unit in cone.units_caught(caster, to, true, true):
		targets.append(unit.anchor(CharacterModel.Anchor.CHEST))
	var blast: Node3D = scene.instantiate()
	context.add_child(blast)
	blast.global_position = apex
	blast.play(along, cone.length, cone.half_angle(), targets)
	caster.notify_impact()
	var gaze := Node3D.new()
	context.add_child(gaze)
	gaze.global_position = apex + along * cone.length
	var gazing: bool = caster.gaze_at(gaze)
	if is_instance_valid(blast) and blast.is_inside_tree():
		await blast.tree_exited
	if gazing and is_instance_valid(caster):
		caster.stop_gazing(gaze_release_seconds)
	# Kept until the head has eased off it: the modifier still reads it.
	gaze.get_tree().create_timer(gaze_release_seconds + 0.1).timeout.connect(gaze.queue_free)


func describe() -> String:
	return "Blasts %s down the cone" % (scene.resource_path.get_file().get_basename() if scene else "(no scene set)")
