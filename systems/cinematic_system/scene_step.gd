class_name SceneStep
extends Resource
## One instruction inside a phase, fired at its offset.
##
## NON-BLOCKING BY DESIGN, unlike VfxStep, whose play() is awaited so a
## projectile genuinely delays the next step. A phase already owns time —
## its duration is the clock, and steps mark positions on it — so a step
## that also consumed time would give a phase two competing notions of how
## long it lasts. A step starts something; the phase decides how long there
## is for it to happen in.
##
## That is what makes a reaction cut expressible: a clip at offset 0 and a
## camera change at offset 1.2 inside the same phase, neither waiting on
## the other. Under a flat awaited chain the cut could only land after the
## clip finished.
##
## Steps must hold no per-play state. A step resource is shared between
## every playthrough of the scene it belongs to, so anything remembered on
## `self` leaks between unrelated plays — the same contract VfxStep states
## and for the same reason.

## Seconds into the phase at which this fires. A step whose offset exceeds
## its phase's duration never fires; CinematicScene.validate() reports that
## rather than letting it disappear.
@export var offset: float = 0.0


func apply(_cast: SceneCast) -> void:
	pass


## One line for a debug overlay or a validation message.
func describe() -> String:
	return "%s at %.2fs" % [get_class(), offset]
