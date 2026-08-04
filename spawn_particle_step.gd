class_name SpawnParticleStep
extends VfxStep
## Instantiates a particle scene at a fixed point in the sequence — the
## caster's position or the target's. Always non-blocking (fires and
## lets the sequence continue immediately) — if you need something later
## in the sequence to wait, use a DelayStep, rather than this step
## growing its own duration/blocking parameters. Keeps this doing
## exactly one thing.
##
## Expects the assigned scene to be SELF-CLEANING (frees itself once its
## effect finishes — a Timer + queue_free(), or a "particles finished"
## signal, whatever fits your own scene setup) — this step has no way to
## know how long an arbitrary particle effect should live, so it doesn't
## try to guess.

enum At { CASTER, TARGET }

@export var scene: PackedScene
@export var at: At = At.TARGET


func play(context: Node, from: Vector3, to: Vector3) -> void:
	if not scene:
		return

	var position: Vector3 = from if at == At.CASTER else to
	var instance := scene.instantiate()
	context.get_tree().current_scene.add_child(instance)
	if instance is Node3D:
		instance.global_position = position


func describe() -> String:
	return "Spawn particles at %s" % ("caster" if at == At.CASTER else "target")
