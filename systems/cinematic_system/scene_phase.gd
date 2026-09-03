class_name ScenePhase
extends Resource
## One beat of a scene: a span of time, and steps that fire at offsets
## inside it.
##
## THE PHASE IS THE ATOM, not the step — and it turned out that the real
## track model this was meant to grow into already shipped with the engine.
## Anything with beats and offsets is now an AnimationPlayer timeline (see
## CinematicStage); what a phase is still for is the ONE shape a timeline
## would be silly for, and it is the shape every line of dialogue asks for:
## a single zero-duration phase carrying a single camera cut, which never
## awaits and therefore costs a conversation nothing.
##
## Which is also why duration was never given the vfx/clip/line sources the
## plan listed for it. The beats that needed those are keys on a timeline
## now, where their lengths are draggable.

@export var duration_seconds: float = 0.0
@export var steps: Array[SceneStep] = []


## Steps that can never fire, because they sit past the end of the phase.
## Reported rather than silently dropped — a step that does nothing looks
## exactly like a step that ran, which is the worst kind of authoring bug.
func unreachable_steps() -> Array[SceneStep]:
	var lost: Array[SceneStep] = []
	for step in steps:
		if step and step.offset > duration_seconds:
			lost.append(step)
	return lost
