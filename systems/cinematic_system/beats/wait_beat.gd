@tool
class_name WaitBeat
extends BeatNode
## Holds the timeline until the player presses cinematic_advance, with
## nothing on screen but the prompt. For a pause that belongs to no line —
## a reveal the player should take in before the scene moves on.
##
## Skipped, it holds nothing: a wait is time, and time is what skip skips.


func _fire(owner_stage: CinematicStage) -> void:
	owner_stage.wait_for_advance()
