extends AiTestCase
## Encounters as instances: more than one fight at a time, and — the point
## of the whole exercise — a unit in NO fight being free to act while one
## runs.
##
## wants_world(): true. With a world loaded, CombatManager.encounters reads
## through WorldContext.encounters rather than the detached _encounters
## fallback (see combat_manager.gd's `encounters` getter), and
## Encounter.world_3d() resolves to the fixture's real World3D instead of
## the bare harness's default one. That is the branch every check in this
## file exercises now instead of the "no world loaded" path.


func wants_world() -> bool:
	return true


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
	await _focused_encounter_follows_the_focus()
	await _the_mode_follows_the_fights_that_are_running()
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

	check("a fight is running", CombatManager.any_combat_running())
	check("the reserve is not in it", not reserve.in_combat())
	check("so combat rules do not bind it — it has unlimited movement",
		not reserve.in_combat() and not reserve.is_my_turn())
	# The distinction the whole refactor turns on: a fight IS happening
	# somewhere, the unit says it isn't in one.
	check("global 'a fight is running' and per-unit 'I am fighting' disagree, correctly",
		CombatManager.any_combat_running() and not reserve.in_combat())

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


## focused_encounter is the one fact CombatManager still holds an opinion
## about — which fight the player is looking at. It used to also forward
## current_unit/turn_order/phase/round_number as properties mirroring the
## focused encounter's own fields, and this case asserted all four stayed
## in sync. Those properties are gone (deleted along with in_combat in the
## same pass that removed CombatManager's other four forwarding accessors
## — see combat_manager.gd's own header): there is nothing left to drift,
## because there is nothing left forwarding. Checks dropped from 6 to 2
## accordingly — what remains is the one thing still worth pinning.
func _focused_encounter_follows_the_focus() -> void:
	_clear_encounters()
	var enemy: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3.ZERO)
	var fighter: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(1.5, 0.0, 0.0))
	var roster: Array[Unit] = [enemy, fighter]
	var fight: Encounter = CombatManager.start_combat(roster)
	await get_tree().process_frame

	check("a fight the player is in takes focus", CombatManager.focused_encounter == fight)

	_clear_encounters()
	await get_tree().process_frame
	check("and with nothing running, focus clears too",
		CombatManager.focused_encounter == null)
	free_spawned()


## The mode reads COMBAT for exactly as long as a watched fight is
## running, and goes back to the base mode when the last one ends.
##
## This used to be a balance test, and the thing it guarded against was
## real: GameMode was a stack, CombatManager pushed COMBAT per encounter
## and popped per encounter-end against its own depth counter, and two
## overlapping fights left it unbalanced — the mode still reading COMBAT
## after both had finished. It was the easiest thing in the file to get
## subtly wrong, so it was asserted in both completion orders.
##
## There is nothing left to balance: the mode is derived, and asks
## CombatManager whether a watched fight is running (see
## a_watched_fight_is_running). A count that cannot drift is better than a
## count asserted to be correct. The BEHAVIOUR is still worth pinning, and
## both completion orders are still worth walking, so the shape stays.
func _the_mode_follows_the_fights_that_are_running() -> void:
	_clear_encounters()
	await get_tree().process_frame
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
	check("two overlapping fights read as COMBAT",
		GameMode.current_mode() == GameMode.Mode.COMBAT)

	# Finish in the opposite order to the one they started in.
	fight_b.finish(&"player")
	await get_tree().process_frame
	check("the first to end leaves the mode alone while one still runs",
		GameMode.current_mode() == GameMode.Mode.COMBAT)

	fight_a.finish(&"player")
	await get_tree().process_frame
	check("the last to end returns the mode to what it was",
		GameMode.current_mode() == mode_before,
		"left as %s, was %s" % [
			GameMode.Mode.keys()[GameMode.current_mode()],
			GameMode.Mode.keys()[mode_before]])

	# The derived form makes one more thing assertable that a stack could
	# only ever be trusted about: with no fight running, the mode IS the
	# base mode, so nothing is left overlaid on it.
	check("and nothing is left overlaid once every fight is over",
		GameMode.can_transition())

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
