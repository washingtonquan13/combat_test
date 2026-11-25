extends "res://tools/combat_rules_demo.gd"
## Recorded look at the sword's swing - NOT a test. The hero cuts at a dummy
## again and again: first under the game's own camera, then under a close
## camera from the side, the front and behind. Shows the three takes (never
## the same twice running), the retimed wind-up, strike and hold, and the
## hitstop and camera knock on a blow that connects.
##
##   tools/render_movie.sh res://tools/sword_swing_demo.tscn recordings/sword/swing_demo.avi

const CLOSE_YAWS := [90.0, 20.0, 270.0]


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	for key in [EquipSlot.Slot.MELEE_MAIN_HAND, EquipSlot.Slot.MELEE_OFF_HAND, EquipSlot.Slot.RANGED_MAIN_HAND, EquipSlot.Slot.RANGED_OFF_HAND]:
		if _hero.get_equipped_item(key):
			_hero.unequip_item(key)
	_hero.equip_item(EquipSlot.Slot.MELEE_MAIN_HAND, ItemInstance.new(IronSword))
	_hero.equip_item(EquipSlot.Slot.CHEST_ARMOR, ItemInstance.new(load("res://data/items/ranger_garb.tres")))
	_dummy = _make_dummy(-1.2)
	SelectionManager.select(_hero)
	await _wait(1.5)

	for i in 3:
		await _cut("Game camera, swing %d" % (i + 1))

	var close := Camera3D.new()
	close.fov = 40.0
	WorldManager.spawn_parent().add_child(close)
	var middle: Vector3 = (_hero.global_position + _dummy.global_position) * 0.5 + Vector3(0, 1.0, 0)
	var facing: float = atan2(_hero.visual_forward().x, _hero.visual_forward().z)
	for yaw: float in CLOSE_YAWS:
		close.global_position = middle + Vector3(0, 0.5, 0) + Basis(Vector3.UP, facing + deg_to_rad(yaw)) * Vector3(0, 0, -4.6)
		close.look_at(middle)
		close.make_current()
		for i in 3:
			await _cut("Close, %d degrees, swing %d" % [int(yaw), i + 1])
	await _wait(1.0)
	get_tree().quit()


func _cut(caption: String) -> void:
	_hero.reset_turn_actions()
	var before: int = _dummy.get_pool(StatIds.HP)
	var result: Dictionary = await _hero.use_ability(_attack("Swing"), _dummy)
	var clip := String(_hero.animator().playback.current_animation)
	var line := "hit for %d" % (before - _dummy.get_pool(StatIds.HP)) if result.get("hit", false) else "no hit"
	_say("%s: %s, %s" % [caption, clip, line])
	print("SWING ", caption, " | ", clip, " | ", line, " | crit ", result.get("critical", false))
	_dummy.set_pool(StatIds.HP, floori(_dummy.get_stat(StatIds.HP)))
	while _hero.is_busy():
		await get_tree().process_frame
	await _wait(0.9)
