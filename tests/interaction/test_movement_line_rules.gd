extends AiTestCase
## When the movement line draws (movement_indicator.gd's header): never
## out of combat unless Shift (select_additive) is held; the hover
## preview in combat; and once the unit walks, the route it committed
## to, without the readout, whatever the cursor does.

var _saved_factions: Array = []


func wants_world() -> bool:
	return true


func run() -> void:
	_saved_factions = CombatAi.ai_factions.duplicate()
	CombatAi.ai_factions = []
	var unit: Unit = spawn_brute(8.0)
	var enemy: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3(2.0, 0.0, 0.0))
	await get_tree().physics_frame

	var line := preload("res://systems/indicator_system/movement_indicator.gd").new()
	add_child(line)
	var aim := Aim.new()
	aim.caster = unit
	aim.point = unit.global_position + Vector3(4.0, 0.0, 0.0)

	line.draw(aim)
	check("out of combat: no line", not line._tube.visible)
	Input.action_press(&"select_additive")
	line.draw(aim)
	Input.action_release(&"select_additive")
	check("out of combat, Shift held: the preview", line._tube.visible)

	var fight: Encounter = CombatManager.start_combat([unit, enemy] as Array[Unit])
	await get_tree().process_frame
	var guard: int = 0
	while fight.is_running and fight.current_unit != unit and guard < 6:
		CombatManager.end_turn(fight.current_unit)
		await get_tree().process_frame
		guard += 1
	check("SETUP: the unit's turn", fight.is_running and fight.current_unit == unit)

	line.draw(aim)
	check("in combat: the hover preview with its readout", line._tube.visible and line._readout.visible)

	unit.move_to(unit.global_position + Vector3(3.0, 0.0, 0.0))
	var walking: PackedVector3Array = unit.current_route().get("path", PackedVector3Array())
	aim.point = unit.global_position + Vector3(0.0, 0.0, 4.0)
	line.draw(aim)
	check("walking: the committed route, not the cursor's",
		unit.is_moving() and line._tube.visible and line._built_path == walking)
	check("walking: no readout", not line._readout.visible)

	for i in 10:
		await get_tree().physics_frame
	var walked: float = unit.move_cost_walked()
	var route_cost: float = unit.current_route().get("cumulative_cost", PackedFloat32Array([0.0]))[-1]
	check("walking: cost walked so far is partway (%.2f of %.2f)" % [walked, route_cost],
		unit.is_moving() and walked > 0.0 and walked < route_cost)

	var feedback := preload("res://systems/indicator_system/click_feedback.gd").new()
	add_child(feedback)
	feedback.hold_destination(unit)
	await get_tree().process_frame
	check("walking: the destination ring holds", feedback._held.has(unit))
	unit.stop_moving()
	await get_tree().process_frame
	check("stopped: the destination ring is gone", not feedback._held.has(unit))
	feedback.queue_free()

	if fight.is_running:
		fight.finish(&"")
	line.queue_free()
	CombatAi.ai_factions = _saved_factions
