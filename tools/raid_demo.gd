extends Node
## Standalone walkthrough — NOT a test, NOT part of tests/run.sh.
## Starts a new game in the goblin quarry and sets the flag the
## townsperson's turn-in sets, so the goblin raid plays at the camp. Once the fight after it has started, prints how the
## scene left everyone and quits. Record it with Movie Maker:
##
##   Godot --resolution 1600x900 --write-movie raid.avi --fixed-fps 30 res://tools/raid_demo.tscn

const MainRootScene: PackedScene = preload("res://MainRoot.tscn")


func _ready() -> void:
	add_child(MainRootScene.instantiate())
	_run.call_deferred()


func _run() -> void:
	await _wait(1.0)
	get_tree().get_first_node_in_group("main_menu")._on_start_pressed()
	await _wait(1.0)
	var creation: Node = get_tree().get_first_node_in_group("character_creation")
	creation._on_auto_fill_pressed()
	await _wait(0.5)
	creation._on_confirm_pressed()
	await WorldManager.world_focused
	var world: Node = WorldManager.current_world()
	await _wait(1.0)
	FlagManager.set_flag("goblin_raid.begun")
	var started := Time.get_ticks_msec()
	var turn_order: Array = await CombatManager.combat_started
	print("DEMO raid ran %.1f s; combat with %d" % [(Time.get_ticks_msec() - started) / 1000.0, turn_order.size()])
	await _wait(3.0)
	for unit in world.find_children("*", "Unit", true, false):
		var u := unit as Unit
		print("DEMO %s alive=%s hp=%d/%d at %s in_combat=%s" % [u.name, u.is_alive(),
			u.get_pool(StatIds.HP), u.get_stat(StatIds.HP), u.global_position.snapped(Vector3.ONE * 0.1), u.in_combat()])
	print("DEMO gate broken ", world.gate_is_broken())
	get_tree().quit()


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
