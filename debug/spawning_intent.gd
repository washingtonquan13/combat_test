class_name SpawningIntent
extends PlayerIntent
## What a click means while the debug spawn panel has a UnitDefinition
## armed: put one there. Pushed onto ClickRouter's intent stack by
## DebugSpawner.arm() and popped by disarm(), so production code never
## names this tool — the router only knows that something outranked the
## ordinary aiming/move behaviour.
##
## Lives under debug/ with the spawner for that reason. It is the whole
## reason push_intent takes a PlayerIntent rather than the router growing
## a "spawning" branch of its own.
##
## Pushed rather than handled from the spawner's own _input(): the game
## world is hosted inside a SubViewport (see world_view.tscn /
## WorldManager.register_world_host), and the SubViewportContainer
## forwards a click into that SubViewport during ITS OWN input callback,
## which runs the world's entire input pipeline SYNCHRONOUSLY — the
## router's _unhandled_input included — before an autoload's _input is
## ever reached. Whichever of those marked the click handled first, the
## autoload would never see it (an armed click would then either
## double-fire — a normal move AND a spawn — or never spawn at all).
## Being INSIDE that same pass, ahead of the router's own behaviour, is
## the only place a click can actually be claimed first. Do not "fix"
## this back to _input(): it looked reasonable and was wrong.

var _spawner: Node


func _init(spawner: Node) -> void:
	_spawner = spawner


func kind() -> StringName:
	return &"spawning"


## left_click with a ground hit: spawns there. left_click with a miss
## (ground null): still claims the click — stays armed rather than
## falling through to a move order, so an accidental miss-click while
## armed can never walk the selected unit somewhere instead.
##
## The armed_definition check is a safety net: an intent left pushed
## after the spawner disarmed must degrade to normal input, never to a
## black hole that swallows every click for the rest of the session.
func handle_left_click(router, hit: ClickHit) -> bool:
	if _spawner.armed_definition == null:
		router.pop_intent(self)
		return false
	if hit.ground != null:
		_spawner.spawn_at(hit.ground)
	return true


func handle_right_click(router, _hit: ClickHit) -> bool:
	if _spawner.armed_definition == null:
		router.pop_intent(self)
		return false
	_spawner.disarm()
	return true


## Nothing. A debug placement is not aiming an ability, and the preview
## overlays would be drawing for a unit that is not the one about to
## exist.
func indicator_ids() -> Array[StringName]:
	return []


func describe() -> String:
	return "spawning"
