class_name SpawnParticleStep
extends VfxStep
## Instantiates a particle scene at a fixed point in the sequence — the
## caster's position or the target's.
##
## If the instantiated scene is shaped like BinbunVFX's VFXController
## (duck-typed — checked via has_method("play") and a child node named
## "AnimationPlayer", not a hard class dependency on third-party script,
## so this step still works correctly with scenes that AREN'T built with
## that controller too), this step actively drives it:
##   - forces one_shot = true (if force_one_shot is on) before it starts
##     playing — several effects in this specific asset family default
##     to CONTINUOUS looping (built for things like a sustained
##     projectile that needs to stay visually "on" for an unknown
##     duration, not a one-shot impact) — this makes an impact/hit
##     effect behave correctly even on a .tscn that wasn't individually
##     configured for one-shot use, rather than depending on every
##     future asset from the pack being remembered to be set up right.
##   - awaits the REAL animation_finished signal instead of guessing a
##     fixed duration, then frees the instance the instant it's actually
##     done — precise rather than estimated.
##
## Falls back to a fixed `fallback_lifetime` timer if no VFXController-
## shaped API is detected, so this still works with plain particle
## scenes that don't use this controller at all.
##
## This IS a real dependency on this specific asset family's shape
## (the "AnimationPlayer" child name, the "play"/"one_shot" duck-typed
## interface) — reasonable for scenes built with it, not a universal
## guarantee for arbitrary future VFX.
##
## IMPORTANT: play() spawns the instance and returns IMMEDIATELY — it
## does NOT wait for the effect to actually finish before letting the
## SEQUENCE continue to whatever step comes next (a PlaySoundStep, say).
## Cleanup (freeing the instance once it's actually done) runs as an
## independent background task instead. An earlier version of this file
## incorrectly awaited that cleanup INSIDE play() itself — which fixed
## effects looping forever, but as a side effect also blocked the next
## step in the sequence from starting until the ENTIRE particle effect
## had finished playing, seconds later. A PlaySoundStep placed after
## this one would then fire long after the actual impact moment, not at
## it — "when should this instance be freed" and "when should the next
## step start" are two different questions; they'd been incorrectly
## tied to the same answer.

enum At { CASTER, TARGET }

@export var scene: PackedScene
@export var at: At = At.TARGET

@export var force_one_shot: bool = true
## Fallback duration, used only if no VFXController-shaped API is found
## on the instantiated scene.
@export var fallback_lifetime: float = 2.0

@export var scale_to_ability_radius: bool = false
@export var authored_radius: float = 1.0
## How much the effect's HEIGHT scales relative to its radius, when
## scale_to_ability_radius is on. 1.0 = uniform (height grows exactly as
## much as radius does — sends every vertically-shooting element
## (sparks, smoke, light rays) proportionally higher as the radius
## grows, which reads as absurd for something that's supposed to be
## WIDE, not TALL). 0.0 = height never changes regardless of radius,
## fully decoupled — verified visually against this specific asset to be
## the right value; the vertical elements were authored at a height that
## already looks correct on their own, independent of blast radius, so
## they shouldn't be touched at all. Values in between interpolate, if a
## different asset actually does want some partial height growth. Pure
## transform math either way: Node3D.scale applies per-axis to
## everything under this node as a group.
@export_range(0.0, 1.0, 0.05) var height_scale_factor: float = 0.0


func play(context: Node, from: Vector3, to: Vector3, ability: Ability = null, _caster: Unit = null) -> void:
	if not scene:
		return

	var position: Vector3 = from if at == At.CASTER else to
	var instance := scene.instantiate()
	WorldManager.spawn_parent().add_child(instance)

	if instance is Node3D:
		instance.global_position = position
		if scale_to_ability_radius and ability and ability.targeting is AreaTargeting:
			var target_radius: float = (ability.targeting as AreaTargeting).radius
			var radius_factor: float = target_radius / max(authored_radius, 0.001)
			var height_factor: float = 1.0 + (radius_factor - 1.0) * height_scale_factor
			instance.scale = Vector3(radius_factor, height_factor, radius_factor)

	# Deliberately NOT awaited — this is what lets play() return right
	# away instead of blocking the sequence. Cleanup happens on its own
	# schedule, independent of whatever step comes next.
	_cleanup_when_done(instance)


func _cleanup_when_done(instance: Node) -> void:
	await _wait_for_completion(instance)
	if is_instance_valid(instance):
		instance.queue_free()


func _wait_for_completion(instance: Node) -> void:
	if force_one_shot and instance.has_method("play"):
		instance.set("one_shot", true)

	var anim_player := instance.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if anim_player and anim_player.is_playing():
		await anim_player.animation_finished
		return

	await instance.get_tree().create_timer(fallback_lifetime).timeout


func describe() -> String:
	return "Spawn particles at %s" % ("caster" if at == At.CASTER else "target")
