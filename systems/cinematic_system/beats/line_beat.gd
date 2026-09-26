@tool
class_name LineBeat
extends BeatNode
## Someone says something: the line goes up in the overlay's subtitle band.
##
## BY DEFAULT IT WAITS for the player (cinematic_advance), which holds the
## timeline — a cutscene line read at a fixed pace is either too fast for
## one reader or too slow for another. A line that should not stop the
## scene (a bark over a walk) turns wait_for_advance off and gives
## auto_seconds instead.
##
## Skipped, a line leaves nothing behind: what was said is not state.

## Who says it. Empty is narration — no speaker name, nobody's head.
@export var role: StringName = &"":
	set(value):
		role = value
		_changed()
## Shown in place of the actor's own name. For a role whose unit's name is
## wrong for the moment ("???" before an introduction), or for narration
## with a voice.
@export var speaker_name: String = ""
@export_multiline var text: String = "":
	set(value):
		text = value
		_changed()
## Hold the timeline until the player advances.
@export var wait_for_advance: bool = true
## With wait_for_advance: advance by itself after this long (0 = never).
## Without: take the line down after this long (0 = leave it up until the
## next line or the end of the scene).
@export_range(0.0, 30.0, 0.1, "suffix:s") var auto_seconds: float = 0.0

## How long a line with nothing else to end it shows in the editor preview.
const PREVIEW_SECONDS: float = 2.0

var _elapsed: float = 0.0


func _validate_property(property: Dictionary) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage and property.name == "role":
		_suggest_names(property, owner_stage.role_names())


func _fire(owner_stage: CinematicStage) -> void:
	_elapsed = 0.0
	owner_stage.show_line(self, _speaker(owner_stage), text)
	if wait_for_advance:
		owner_stage.wait_for_advance()
		owner_stage.run(self)
	elif auto_seconds > 0.0:
		owner_stage.run(self)


## Holds the line while the scene waits on it, or counts it down. Polled —
## the line learns the player advanced by the stage no longer waiting, not
## by a signal.
func tick(delta: float) -> bool:
	var owner_stage: CinematicStage = _live_stage()
	if owner_stage == null:
		return false
	_elapsed += delta
	if wait_for_advance:
		if owner_stage.is_waiting():
			if auto_seconds <= 0.0 or _elapsed < auto_seconds:
				return true
			owner_stage.advance()
	elif _elapsed < auto_seconds:
		return true
	owner_stage.clear_line(self)
	return false


func _finish(owner_stage: CinematicStage) -> void:
	owner_stage.clear_line(self)


func _speaker(owner_stage: CinematicStage) -> String:
	if speaker_name != "":
		return speaker_name
	if role == &"":
		return ""
	var speaking: Unit = owner_stage.actor(role)
	return speaking.get_display_name() if speaking else String(role).capitalize()


## A label over the speaker's stand-in from the key until the next line
## (or auto_seconds, for a line that takes itself down). The editor never
## waits for input, so a waiting line shows until the next one.
func preview(seconds_since_fire: float) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage == null or role == &"" or seconds_since_fire < 0.0:
		return
	if seconds_since_fire >= _preview_window(owner_stage):
		return
	var marker: StageRole = owner_stage.role_marker(role)
	var label: Label3D = marker.preview_label() if marker else null
	if label == null:
		return
	label.text = text
	label.visible = true


func _preview_window(owner_stage: CinematicStage) -> float:
	if not wait_for_advance and auto_seconds > 0.0:
		return auto_seconds
	var mine: float = owner_stage.fire_time_of(self)
	for pair in owner_stage.timed_beats():
		if pair[0] != self and pair[0] is LineBeat and float(pair[1]) > mine:
			return float(pair[1]) - mine
	var anim: Animation = owner_stage.performance()
	return maxf(anim.length - mine, PREVIEW_SECONDS) if anim else PREVIEW_SECONDS


func _beat_warnings(owner_stage: CinematicStage) -> PackedStringArray:
	var warnings := PackedStringArray()
	if role != &"":
		_check_role(warnings, owner_stage, "role", role)
	if text.strip_edges() == "":
		warnings.append("'text' is empty.")
	return warnings
