class_name ScenePhase
extends Resource
## One beat of a scene: a span of time, and steps that fire at offsets
## inside it.
##
## THE PHASE IS THE ATOM, not the step, and that is what lets this grow
## into a real track model instead of being replaced by one. A flat list of
## steps awaited in order can only put a camera change AFTER whatever
## precedes it — so a reaction cut, where the shot changes 1.2 seconds into
## a line that is still being spoken, is inexpressible. Offsets inside a
## phase make it ordinary. Ship with one step at offset zero and this
## authors exactly like a flat list; add a second offset and it does not
## need re-timing.
##
## DURATION IS FIXED FOR NOW. The plan orders the real sources vfx, clip,
## fixed, line — four of the fusion cutscene's eight beats are as long as
## their effect and nothing else, and hand-timing those against VFX that
## does not exist yet is the same brittleness that makes hard-coded
## timestamps wrong. Phase 2 adds them; `fixed` is the one that needs no
## machinery, so it is the one that exists.

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
