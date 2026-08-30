extends AiTestCase
## Encounters as instances: more than one fight at a time, and — the point
## of the whole exercise — a unit in NO fight being free to act while one
## runs.


func run() -> void:
	_saved_ai_factions = CombatAi.ai_factions.duplicate()
	# CombatAI off throughout. start_combat defers the first turn to it, and
	# it then drives real movement while these cases tear the battlefield
	# down around it — which segfaults. What's under test is turn-order and
	# membership bookkeeping, not how a unit spends its turn.
	CombatAi.ai_factions = [] as Array[StringName]

	await _two_fights_at_once()
	await _a_unit_outside_a_fight_is_free()
	await _a_unit_inside_a_fight_is_not()
	await _legacy_accessors_follow_the_focus()
	await _game_mode_stack_stays_balanced()
	await _joining_picks_the_right_fight()

	CombatAi.ai_factions = _saved_ai_factions


var _saved_ai_factions: Array[StringName] = []


## Two fights, far apart, running simultaneously with independent state.
func _two_fights_at_once() -> void:
	_clear_encounters()
	var a1: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3.ZERO)
	var a2: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(1.5, 0.0, 0.0))
	var b1: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3(0.0, 0.0, 300.0))
	var b2: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(1.5, 0.0, 300.0))

	var roster_a: Array[Unit] = [a1, a2]
	var roster_b: Array[Unit] = [b1, b2]
	var fight_a: Encounter = CombatManager.start_combat(roster_a)
	var fight_b: Encounter = CombatManager.start_combat(roster_b)
	await get_tree().process_frame

	check("two encounters run at once", CombatManager.encounters.size() == 2)
	check("each has its own turn order",
		fight_a.turn_order.size() == 2 and fight_b.turn_order.size() == 2
			and not fight_a.turn_order.has(b1))
	check("a unit knows which fight it is in",
		a1.encounter == fight_a and b1.encounter == fight_b)

	fight_a.finish(&"player")
	# Asserted through the survivors, not through fight_a — finishing an
	# encounter queue_frees it, so reading anything off it after this point
	# is reading a freed object.
	check("ending one leaves the other running", fight_b.is_running)
	check("and the finished one is dropped from the set",
		CombatManager.encounters.size() == 1)
	check("its combatants are released from it",
		a1.encounter == null and a2.encounter == null)
	check("while the other fight keeps its own",
		b1.encounter == fight_b and b2.encounter == fight_b)
	await get_tree().process_frame

	_clear_encounters()
	await get_tree().process_frame
	free_spawned()


## THE POINT. A party member held out of a battle can be commanded while
## that battle runs — which is what makes an ambush possible at all.
func _a_unit_outside_a_fight_is_free() -> void:
	_clear_encounters()
	var enemy: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3.ZERO)
	var fighter: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(1.5, 0.0, 0.0))
	var reserve: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(0.0, 0.0, 40.0))

	var roster: Array[Unit] = [enemy, fighter]
	CombatManager.start_combat(roster)
	await get_tree().process_frame

	check("a fight is running", CombatManager.in_combat)
	check("the reserve is not in it", not reserve.in_combat())
	check("so combat rules do not bind it — it has unlimited movement",
		not reserve.in_combat() and not reserve.is_my_turn())
	# The distinction the whole refactor turns on: the manager says a fight
	# is happening, the unit says it isn't in one.
	check("global 'a fight is running' and per-unit 'I am fighting' disagree, correctly",
		CombatManager.in_combat and not reserve.in_combat())

	_clear_encounters()
	await get_tree().process_frame
	free_spawned()


func _a_unit_inside_a_fight_is_not() -> void:
	_clear_encounters()
	var enemy: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3.ZERO)
	var fighter: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(1.5, 0.0, 0.0))
	var roster: Array[Unit] = [enemy, fighter]
	var fight: Encounter = CombatManager.start_combat(roster)
	await get_tree().process_frame

	var acting: Unit = fight.current_unit
	var waiting: Unit = enemy if acting == fighter else fighter
	check("both are bound by the fight",
		enemy.in_combat() and fighter.in_combat())
	check("exactly one of them has the turn",
		acting.is_my_turn() and not waiting.is_my_turn())

	_clear_encounters()
	await get_tree().process_frame
	free_spawned()


## The delegating accessors are what let every UI reader keep working
## untouched — if they drift from the focused encounter, the UI silently
## reports on the wrong fight.
func _legacy_accessors_follow_the_focus() -> void:
	_clear_encounters()
	var enemy: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3.ZERO)
	var fighter: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(1.5, 0.0, 0.0))
	var roster: Array[Unit] = [enemy, fighter]
	var fight: Encounter = CombatManager.start_combat(roster)
	await get_tree().process_frame

	check("a fight the player is in takes focus", CombatManager.focused_encounter == fight)
	check("current_unit delegates", CombatManager.current_unit == fight.current_unit)
	check("turn_order delegates", CombatManager.turn_order.size() == fight.turn_order.size())
	check("phase delegates", CombatManager.phase == fight.phase)
	check("round_number delegates", CombatManager.round_number == fight.round_number)

	_clear_encounters()
	await get_tree().process_frame
	check("and with nothing running, in_combat is false again",
		not CombatManager.in_combat)
	free_spawned()


## GameMode is a STACK. Pushing COMBAT per encounter and popping per
## encounter-end leaves it unbalanced the moment two overlap — the mode
## would still read COMBAT after both finished. Easiest thing here to get
## subtly wrong, so asserted in both completion orders.
func _game_mode_stack_stays_balanced() -> void:
	_clear_encounters()
	await get_tree().process_frame
	var depth_before: int = CombatManager._combat_mode_depth
	var mode_before: GameMode.Mode = GameMode.current_mode()

	var a1: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3.ZERO)
	var a2: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(1.5, 0.0, 0.0))
	var b1: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3(0.0, 0.0, 300.0))
	var b2: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(1.5, 0.0, 300.0))
	var roster_a: Array[Unit] = [a1, a2]
	var roster_b: Array[Unit] = [b1, b2]

	var fight_a: Encounter = CombatManager.start_combat(roster_a)
	var fight_b: Encounter = CombatManager.start_combat(roster_b)
	await get_tree().process_frame
	check("two overlapping fights push COMBAT once, not twice",
		CombatManager._combat_mode_depth == depth_before + 2
			and GameMode.current_mode() == GameMode.Mode.COMBAT)

	# Finish in the opposite order to the one they started in.
	fight_b.finish(&"player")
	await get_tree().process_frame
	check("the first to end does not pop the mode while one still runs",
		GameMode.current_mode() == GameMode.Mode.COMBAT)

	fight_a.finish(&"player")
	await get_tree().process_frame
	check("the last to end restores the mode exactly",
		GameMode.current_mode() == mode_before
			and CombatManager._combat_mode_depth == depth_before)

	_clear_encounters()
	await get_tree().process_frame
	free_spawned()


## A latecomer must join the fight it actually walked into, not whichever
## one happens to be first in the list.
func _joining_picks_the_right_fight() -> void:
	_clear_encounters()
	var a1: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3.ZERO)
	var a2: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(1.5, 0.0, 0.0))
	var b1: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3(0.0, 0.0, 300.0))
	var b2: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(1.5, 0.0, 300.0))
	var roster_a: Array[Unit] = [a1, a2]
	var roster_b: Array[Unit] = [b1, b2]
	var fight_a: Encounter = CombatManager.start_combat(roster_a)
	var fight_b: Encounter = CombatManager.start_combat(roster_b)
	await get_tree().process_frame

	# Standing next to fight B, on the far side of the map from fight A.
	var latecomer: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3(3.0, 0.0, 300.0))
	DetectionManager.scan()

	check("the latecomer joined the fight it was standing in",
		latecomer.encounter == fight_b, "joined %s" % (
			"A" if latecomer.encounter == fight_a else
			("B" if latecomer.encounter == fight_b else "nothing")))
	check("and not the distant one", not fight_a.turn_order.has(latecomer))

	_clear_encounters()
	await get_tree().process_frame
	free_spawned()


## Encounters outlive a single case (they're children of CombatManager), so
## each case starts from none running rather than inheriting the last one's.
func _clear_encounters() -> void:
	# is_instance_valid, because finishing one frees it — and this iterates
	# a snapshot taken before that happened.
	for encounter in CombatManager.encounters.duplicate():
		if is_instance_valid(encounter) and encounter.is_running:
			encounter.finish(&"")
