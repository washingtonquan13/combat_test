class_name VfxStep
extends Resource
## Base class for one piece of a composable VFX sequence (see VfxEffect)
## — spawn a particle burst, play a sound, wait, animate a projectile
## traveling between two points. Same composition philosophy as
## AbilityEffect: small, reusable, single-purpose pieces combined into a
## sequence, rather than one flat "explosion effect" class trying to
## cover every possible VFX shape.
##
## play() is an async coroutine — anything that takes real time (a
## Tween, a timer) uses `await` internally. VfxEffect awaits each step
## in turn, so a step representing something with genuine duration (a
## projectile actually flying) truly blocks the NEXT step from starting
## until it's done, without VfxEffect needing to know anything about how
## long any given step takes.
##
## context is a live, persistent Node (see VfxEffect.play's doc comment
## for why it should be the scene root, not either combatant) used
## purely for tree access — spawning children, creating Tweens — since a
## Resource has no tree presence of its own to do either.
##
## Steps must not store any per-play state as instance fields (only
## configuration @export values) — this Resource can be shared and
## played concurrently by multiple simultaneous effects (two fireballs
## cast at once, sharing the same VfxEffect resource), and instance
## field state would leak between those unrelated plays. Local variables
## inside play() are safe (each call gets its own stack frame); fields
## on self are not.

## from/to are the caster's and target's positions at the moment the
## WHOLE sequence started, not re-evaluated per step — a step doesn't
## need to know which step number it is or where in the sequence it
## sits, just the two points the sequence is playing between. ability is
## the Ability that triggered this sequence (optional, null for
## sequences not tied to an ability use — e.g. a death effect) — most
## steps ignore it, but it's there for the ones that need to read
## gameplay data, e.g. SpawnParticleStep optionally scaling itself to
## match AreaTargeting's actual blast radius. caster is the attacking
## Unit (also optional, null for the same non-ability-tied sequences) —
## needed by ImpactSignalStep to call caster.notify_impact(), which is
## what actually unblocks a waits_for_impact ability's damage
## resolution at exactly the moment this step is reached in the sequence.
func play(_context: Node, _from: Vector3, _to: Vector3, _ability: Ability = null, _caster: Unit = null) -> void:
	pass


## Human-readable summary for tooltips/editor clarity. Override in each
## subclass.
func describe() -> String:
	return ""


## The unit standing exactly at point, or null. UnitVfx passes a unit
## target as its global_position, so that is the one aimed at.
static func unit_at(tree: SceneTree, point: Vector3) -> Unit:
	for node in tree.get_nodes_in_group(&"units"):
		if node is Unit and node.global_position.distance_squared_to(point) < 0.0001:
			return node
	return null


## Lets a projectile scene play out its arrival before it is freed: a
## scene whose root has an arrive() coroutine runs it (fx going out,
## a burst at the hit), or one with an "arrive" animation on a child
## AnimationPlayer plays that. Not awaited by the steps, so the impact
## is not held up.
static func arrive_and_free(wrapper: Node3D, instance: Node) -> void:
	if instance.has_method(&"arrive"):
		await instance.arrive()
	else:
		var player := instance.get_node_or_null("AnimationPlayer") as AnimationPlayer
		if player and player.has_animation(&"arrive"):
			player.play(&"arrive")
			await player.animation_finished
	if is_instance_valid(wrapper):
		wrapper.queue_free()
