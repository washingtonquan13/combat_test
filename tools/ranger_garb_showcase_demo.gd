extends Node
## Standalone recorded walkthrough — NOT a test, NOT part of tests/run.sh.
## Boots the real game and plays cinematics/ranger_garb_showcase.tscn at the
## leader: the hero and the townsperson in the Ranger's Garb. The hero's
## weapons come off first so the back of the coat shows. Clicks through
## each line after a few seconds.
##
##   tools/render_movie.sh res://tools/ranger_garb_showcase_demo.tscn out.avi

const MainRootScene: PackedScene = preload("res://MainRoot.tscn")
const SCENE := "res://cinematics/ranger_garb_showcase.tscn"
const READ_SECONDS := 3.0


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
	# Weapons off, so the back of the coat shows: the bow and shield
	# would cover it. Only this recording; nothing is saved.
	for slot in [EquipSlot.Slot.SET_1_MAIN_HAND, EquipSlot.Slot.SET_1_OFF_HAND,
			EquipSlot.Slot.SET_2_MAIN_HAND, EquipSlot.Slot.SET_2_OFF_HAND]:
		PartyManager.leader.unequip_item(slot)
	await _wait(2.0)
	_click_through()
	print("DEMO played ", await CinematicDirector.play(load(SCENE)))
	await _wait(1.0)
	get_tree().quit()


## Clicks a held line on once it has been up a few seconds.
func _click_through() -> void:
	while not CinematicDirector.is_active():
		await get_tree().process_frame
	var held := 0.0
	while CinematicDirector.is_active():
		await get_tree().process_frame
		var waiting := false
		for scene in get_tree().root.find_children("*", "Cutscene", true, false):
			waiting = waiting or (scene as Cutscene).is_waiting()
		held = held + get_process_delta_time() if waiting else 0.0
		if held >= READ_SECONDS:
			held = 0.0
			for down in [true, false]:
				var press := InputEventAction.new()
				press.action = &"cinematic_advance"
				press.pressed = down
				Input.parse_input_event(press)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
