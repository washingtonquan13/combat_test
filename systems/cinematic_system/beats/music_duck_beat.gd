@tool
class_name MusicDuckBeat
extends BeatNode
## Ducks the score (Music.duck) or brings it back (Music.unduck). A kill
## lands in silence when the music has gone a moment before it (spec 5.1:
## silent or ducked at least 0.5 s before).
##
## Skipped, it brings the music back: a skipped scene must not leave the
## game ducked.

@export var duck: bool = true:
	set(value):
		duck = value
		_changed()
## The level ducked to; -60 is silent.
@export_range(-60.0, 0.0, 1.0, "suffix:dB") var db: float = -60.0
@export_range(0.0, 3.0, 0.05, "suffix:s") var seconds: float = 0.25


func _fire(_owner_stage: CinematicStage) -> void:
	var music: Node = _music()
	if music == null:
		return
	if duck:
		music.duck(db, seconds)
	else:
		music.unduck(seconds)


func _skip(_owner_stage: CinematicStage) -> void:
	var music: Node = _music()
	if music:
		music.unduck(0.0 if duck else seconds)


func _music() -> Node:
	if Engine.is_editor_hint():
		return null
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null("Music") if tree else null
