extends Node
## Standalone walkthrough — NOT a test, NOT part of tests/run.sh.
## Boots the real game into the quarry, puts the leader in the goblin camp's
## trigger, and lets the ambush cutscene play. The cutscene performs on
## stand-ins (CinematicStage.performs_on_stand_ins): the log prints where the
## hobgoblin's unit is and where it is seen to be, while it walks and after
## the scene hands its end state to the fight.
##
##   Godot --resolution 1600x900 --write-movie <out.avi> --fixed-fps 30 res://tools/ambush_stand_ins_demo.tscn

const MainRootScene: PackedScene = preload("res://MainRoot.tscn")
const TRIGGER_SPOT := Vector3(14.5, -5.47, -26.5)
const WATCHED: Array[String] = ["Hobgoblin", "GoblinRogue", "Watchman"]


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
	await _wait(2.0)

	var area: Node = WorldManager.spawn_parent()
	var watched: Array[Unit] = []
	for unit_name in WATCHED:
		watched.append(area.find_child(unit_name, true, false) as Unit)
	var was: Array[Vector3] = []
	for unit in watched:
		was.append(unit.global_position)
	PartyManager.leader.global_position = TRIGGER_SPOT

	var seen_any := false
	var clock := 0.0
	var next_print := 0.0
	var next_advance := 9.0
	while clock < 40.0:
		await get_tree().process_frame
		clock += get_process_delta_time()
		var up: bool = StandIn.of(watched[0]) != null
		seen_any = seen_any or up
		if clock >= next_print:
			next_print += 1.0
			for i in watched.size():
				var unit: Unit = watched[i]
				print("DEMO t=%.1f %s unit moved %.2f m, seen %.2f m from its unit, stand-in %s, in combat %s" % [
					clock, unit.name, unit.global_position.distance_to(was[i]),
					StandIn.place_of(unit).distance_to(unit.global_position),
					StandIn.of(unit) != null, unit.in_combat()])
		if up and clock >= next_advance:
			next_advance += 2.5
			var advance := InputEventAction.new()
			advance.action = &"cinematic_advance"
			advance.pressed = true
			Input.parse_input_event(advance)
		if seen_any and not up and watched[0].in_combat():
			break
	await _wait(3.0)
	for i in watched.size():
		var unit: Unit = watched[i]
		print("DEMO end %s at %s, moved %.2f m, stand-in %s, in combat %s" % [
			unit.name, unit.global_position, unit.global_position.distance_to(was[i]),
			StandIn.of(unit) != null, unit.in_combat()])
	print("DEMO done")
	get_tree().quit()


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
