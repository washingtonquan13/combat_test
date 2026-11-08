class_name BeamStep
extends VfxStep
## A held beam from the caster's hand to the target (a ray, not a
## projectile): it shoots out over reach_time, then the beam scene holds
## and fades on its own. The step ends when the beam reaches the target,
## so an ImpactSignalStep after it lands the hit on that moment.
##
## Straight, from the hand to the target's chest - the shot the rules
## trace (LineOfSight.shot_to) - so it never routes around anything; the
## ability needs a clear line, and its preview is the straight
## line-of-sight one.
##
## The beam scene's root needs fire(from, to, reach_time, caster,
## launch_from): see scenes/vfx/ice/frost_ray.gd.

@export var beam_scene: PackedScene
@export var launch_from: CharacterModel.Anchor = CharacterModel.Anchor.HAND
## Seconds the beam takes to reach the target.
@export var reach_time: float = 0.1


func play(context: Node, from: Vector3, to: Vector3, _ability: Ability = null, caster: Unit = null) -> void:
	if not beam_scene:
		return
	var target: Unit = unit_at(context.get_tree(), to)
	var end: Vector3 = LineOfSight.shot_to(target, caster if is_instance_valid(caster) else null) if target else to
	if launch_from != CharacterModel.Anchor.GROUND and is_instance_valid(caster):
		from = caster.anchor(launch_from)
	var beam := beam_scene.instantiate()
	WorldManager.spawn_parent().add_child(beam)
	beam.fire(from, end, reach_time, caster, launch_from)
	await context.get_tree().create_timer(reach_time).timeout


func describe() -> String:
	return "Beam: reaches in %.2fs" % reach_time
