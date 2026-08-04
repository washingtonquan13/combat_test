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

enum At { CASTER, TARGET }

@export var scene: PackedScene
@export var at: At = At.TARGET

@export var force_one_shot: bool = true
## Fallback duration, used only if no VFXController-shaped API is found
## on the instantiated scene.
@export var fallback_lifetime: float = 2.0

@export var scale_to_ability_radius: bool = false
@export var authored_radius: float = 1.0


func play(context: Node, from: Vector3, to: Vector3, ability: Ability = null) -> void:
	if not scene:
		return

	var position: Vector3 = from if at == At.CASTER else to
	var instance := scene.instantiate()
	context.get_tree().current_scene.add_child(instance)

	if instance is Node3D:
		instance.global_position = position
		if scale_to_ability_radius and ability and ability.targeting is AreaTargeting:
			var target_radius: float = (ability.targeting as AreaTargeting).radius
			var factor: float = target_radius / max(authored_radius, 0.001)
			instance.scale = Vector3.ONE * factor

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
