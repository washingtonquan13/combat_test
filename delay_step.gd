class_name DelayStep
extends VfxStep
## Pauses the sequence for a fixed duration before letting the next step
## start. The explicit way to insert a gap between two otherwise
## non-blocking steps (a cast-flash, then a beat, then the projectile
## launches) — kept as its own step rather than every other step type
## growing its own optional delay/blocking parameters.

@export var duration: float = 0.5


func play(context: Node, _from: Vector3, _to: Vector3) -> void:
	await context.get_tree().create_timer(duration).timeout


func describe() -> String:
	return "Wait %.2fs" % duration
