extends "res://tools/tier3_demo.gd"
## Recorded showcase of when the movement line draws (10cc67c) - NOT a test.
## Record WITHOUT opengl3 (decals need Forward+).


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.select(_hero)
	var saved_factions: Array = CombatAi.ai_factions.duplicate()
	CombatAi.ai_factions = []
	_frame(_spot(-3.0, 0.0), 10.0)
	await _wait(2.0)

	_say("Out of combat: hovering draws no line")
	await _glide(_screen(_spot(-5.0, 1.5)), 0, 40)
	await _wait(0.8)
	await _glide(_screen(_spot(-7.0, -2.0)), 0, 40)
	await _wait(1.0)
	_say("Out of combat: click - marker only, no line")
	await _click(_screen(_spot(-5.0, 0.0)))
	await _wait(3.0)

	_say("Out of combat, Shift held: path preview")
	Input.action_press(&"select_additive")
	await _glide(_screen(_spot(-4.0, 2.0)), 0, 40)
	await _wait(0.8)
	await _glide(_screen(_spot(-6.0, -2.0)), 0, 40)
	await _wait(1.5)
	Input.action_release(&"select_additive")
	_say("Shift released: gone")
	await _glide(_screen(_spot(-5.0, -1.0)), 0, 20)
	await _wait(1.5)

	var foe: Unit = _dummy(10.0, 6.0)
	foe.faction = &"enemy"
	var fight: Encounter = CombatManager.running_encounter_in_world_of(_hero)
	if fight == null:
		fight = CombatManager.start_combat([_hero, foe] as Array[Unit])
	await _wait(0.3)
	var guard := 0
	while fight.is_running and fight.current_unit != _hero and guard < 8:
		CombatManager.end_turn(fight.current_unit)
		await _wait(0.2)
		guard += 1
	_frame(_spot(-3.0, 0.0), 11.0)
	_say("In combat: hover preview + distance readout")
	await _wait(1.5)
	await _glide(_screen(_spot(-4.0, 1.5)), 0, 40)
	await _wait(1.2)
	await _glide(_screen(_spot(-6.0, -2.0)), 0, 40)
	await _wait(1.2)
	_say("Past the budget: the over-budget part turns crimson")
	await _glide(_screen(_spot(-14.0, 0.0)), 0, 50)
	await _wait(2.0)

	_say("Click: only the committed route, no readout, until arrival (walk slowed 3x)")
	await _click(_screen(_spot(-7.0, -2.5)))
	Engine.time_scale = 0.33
	await _glide(_screen(_spot(-1.0, -4.0)), 0, 50)
	await _glide(_screen(_spot(-8.0, 4.0)), 0, 50)
	await _glide(_screen(_spot(-2.0, 3.0)), 0, 50)
	var timeout := 0.0
	while _hero.is_moving() and timeout < 8.0:
		await _wait(0.1)
		timeout += 0.1
	Engine.time_scale = 1.0
	_say("Arrived: hover preview returns")
	await _glide(_screen(_spot(-3.0, -2.0)), 0, 40)
	await _wait(2.5)

	if fight.is_running:
		fight.finish(&"")
	CombatAi.ai_factions = saved_factions
	await _wait(0.5)
	get_tree().quit()
