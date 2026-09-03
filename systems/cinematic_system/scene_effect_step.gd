class_name SceneEffectStep
extends SceneStep
## Plays a VfxEffect during a scene.
##
## The project already had a composable effect system — ordered VfxSteps
## for particles, projectiles, sound and delay, proven by every ability in
## the game — sitting entirely unreachable from a cutscene. This is the
## bridge, and it is deliberately thin: a scene should not grow its own
## parallel vocabulary for spectacle when a working one is right there.
##
## It also unblocks fusion's four empty beats. Lightning and the mesh
## dissolve are still new shader work, but the flash and the coalescing
## energy sphere have a head start in the imported pack (see the 2026-08-26
## asset audit), and both arrive as VfxSteps in an effect this can play.
##
## FIRE AND FORGET. VfxEffect.play() is a coroutine, and this does not
## await it — a step marks a position on the phase's clock and the phase
## owns time. An effect longer than its phase simply outlives it, the same
## way an ability's effect outlives the ability.

@export var effect: VfxEffect
## Where the effect starts, and where it ends — a projectile needs both, a
## particle burst only uses the first. Marks win over roles when both are
## given, matching CameraFraming.
@export var from_role: StringName = &""
@export var from_mark: StringName = &""
@export var to_role: StringName = &""
@export var to_mark: StringName = &""


func apply(cast: SceneCast) -> void:
	if effect == null:
		return
	# The scene root, not an actor — an actor freed mid-effect takes any
	# Tween it owns with it, cutting the visual off. VfxEffect's own header
	# makes the same point about passing the caster.
	var context: Node = WorldManager.spawn_parent()
	if context == null or not context.is_inside_tree():
		return
	var from: Vector3 = cast.point(from_mark, from_role)
	var to: Vector3 = cast.point(to_mark, to_role) if (to_mark != &"" or to_role != &"") else from
	effect.play(context, from, to)


func describe() -> String:
	return "effect at '%s' at %.2fs" % [
		from_mark if from_mark != &"" else from_role, offset]
