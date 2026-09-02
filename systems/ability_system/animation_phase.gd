@tool
class_name AnimationPhase
extends Resource
## One clip within an AnimationSequence, plus data describing how the
## sequence advances past it — see AnimationSequence's own header for
## why this data lives here rather than the phase driving its own
## playback the way VfxStep does.

enum AdvanceTrigger {
	ON_FINISH,  ## Advance when AnimationPlayer.animation_finished fires
	            ## for this phase's own animation_name — the common
	            ## case (a swing, a spell's Enter/Shoot/Exit, Jump's
	            ## Start).
	ON_TIMER,   ## Advance after `duration` seconds regardless of the
	            ## clip's own length — for a clip authored to loop
	            ## indefinitely (an "Idle"-named hold) that would never
	            ## fire animation_finished on its own.
	EXTERNAL,   ## Doesn't self-advance — waits for unrelated gameplay
	            ## logic to call unit_animator.gd's advance_external().
	            ## For a phase whose end is a physical event with no
	            ## animation-side signal of its own (Jump's Loop, which
	            ## only ends once MoveCasterEffect's Tween completes).
}

@export var animation_name: String = ""
@export var advance_trigger: AdvanceTrigger = AdvanceTrigger.ON_FINISH
## Only read when advance_trigger == ON_TIMER.
@export var duration: float = 0.3


func describe() -> String:
	match advance_trigger:
		AdvanceTrigger.ON_FINISH:
			return "%s (until finished)" % animation_name
		AdvanceTrigger.ON_TIMER:
			return "%s (%.2fs)" % [animation_name, duration]
		AdvanceTrigger.EXTERNAL:
			return "%s (external)" % animation_name
	return animation_name
