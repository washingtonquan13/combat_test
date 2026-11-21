@tool
class_name DirectedScene
extends Node3D
## What CinematicDirector.play() needs from the root of a scene it plays.
##
## Two roots answer it: Cutscene (hand-keyed, the way scenes are made now)
## and CinematicStage (the beat-driven one the older scenes still use). The
## director only ever talks to this.

## The AnimationPlayer whose animation is the performance.
func timeline() -> AnimationPlayer:
	return get_node_or_null(^"Timeline") as AnimationPlayer


## Called once the scene is in the world, before its timeline plays.
func bind(_cast: SceneCast) -> void:
	pass


## Called when the scene is over, however it ended.
func unbind() -> void:
	pass


## Still performing: playing, or held for the player.
func is_running() -> bool:
	return false


## Held until the player presses advance.
func is_waiting() -> bool:
	return false


func advance() -> void:
	pass


## Puts everything in the state the last frame leaves it in.
func skip_to_end() -> void:
	pass


## Hands the scene's end state to the real units. Only called for a scene
## that reached its end (finished, skipped or settled).
func commit_stand_ins() -> void:
	pass
