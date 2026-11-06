extends AiTestCase
## Getting into a fight that's already running, and getting out of one.
##
## Both are the same system as detection wearing different hats: joining is
## perceiving a fight you weren't in, leaving is nobody being able to
## perceive you any more.
##
## wants_world(): true. Joining goes through DetectionManager._react_to,
## which gates on CombatManager.combat_running_in_world_of(observer) — with
## no world loaded that reads the same default World3D every node in the
## bare harness shares, so the check passed even if the per-world lookup
## were broken. With the fixture loaded it is a real per-world query.


const SWEEPS: int = 40

var _saved_ai_factions: Array[StringName] = []


func wants_world() -> bool:
	return true


func run() -> void:
	# CombatAI off for the duration. start_combat() defers _advance_turn,
	# which hands the turn straight to the AI — it then drives real
	# movement and pathing while these cases are tearing the battlefield
	# down around it, which segfaults. What's under test here is
	# CombatManager's roster and turn-order bookkeeping; how a unit spends
	# its turn is the ai suite's job.
	_saved_ai_factions = CombatAi.ai_factions.duplicate()
	CombatAi.ai_factions = [] as Array[StringName]

	await _reinforcement_joins()
	await _player_straggler_joins()
	await _neutral_bystander_stays_out()
	await _distant_bystander_does_not_join()
	await _turn_index_survives_a_join()
	await _escaping_leaves_the_fight()
	await _last_one_out_ends_it()
	await _escape_does_not_forgive()

	CombatAi.ai_factions = _saved_ai_factions


## BG3's shouting range: a fight is loud, and people nearby come running.
func _reinforcement_joins() -> void:
	_ensure_out_of_combat()
	var fighter: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3.ZERO)
	var player: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(1.5, 0.0, 0.0))
	var nearby: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3(0.0, 0.0, 8.0))
	# Facing away, so it cannot be SEEING the fight — hearing is the whole
	# point of this case.
	nearby.snap_face_point(Vector3(0.0, 0.0, 60.0))

	var roster: Array[Unit] = [fighter, player]
	var fight: Encounter = CombatManager.start_combat(roster)
	await get_tree().process_frame
	check("the reinforcement starts outside the fight",
		not fight.turn_order.has(nearby))

	for i in SWEEPS:
		DetectionManager.scan()
		if fight.turn_order.has(nearby):
			break
	check("a hostile within earshot of a fight joins it",
		fight.turn_order.has(nearby))

	_ensure_out_of_combat()
	await get_tree().process_frame
	free_spawned()


func _distant_bystander_does_not_join() -> void:
	_ensure_out_of_combat()
	var fighter: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3.ZERO)
	var player: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(1.5, 0.0, 0.0))
	var far_away: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3(0.0, 0.0, 120.0))
	far_away.snap_face_point(Vector3(0.0, 0.0, 300.0))

	var roster: Array[Unit] = [fighter, player]
	var fight: Encounter = CombatManager.start_combat(roster)
	await get_tree().process_frame
	for i in SWEEPS:
		DetectionManager.scan()
	check("a hostile far out of earshot does NOT join",
		not fight.turn_order.has(far_away))

	_ensure_out_of_combat()
	await get_tree().process_frame
	free_spawned()


## The gap that made this fix necessary: DetectionManager never treats a
## party member as an OBSERVER (so the party can't start fights on its
## own), and that exclusion silently meant a player unit left out of a
## fight could stand in the middle of one forever, unable to join.
func _player_straggler_joins() -> void:
	_ensure_out_of_combat()
	var enemy: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3.ZERO)
	var fighter: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(1.5, 0.0, 0.0))
	var straggler: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(0.0, 0.0, 6.0))

	var roster: Array[Unit] = [enemy, fighter]
	var fight: Encounter = CombatManager.start_combat(roster)
	await get_tree().process_frame
	check("the straggler starts outside the fight",
		not fight.turn_order.has(straggler))

	DetectionManager.scan()
	check("a player unit standing in an ongoing fight joins it",
		fight.turn_order.has(straggler))

	_ensure_out_of_combat()
	await get_tree().process_frame
	free_spawned()


## ...but only somebody's enemy. Standing near a brawl you have no stake
## in is not joining it.
func _neutral_bystander_stays_out() -> void:
	_ensure_out_of_combat()
	var enemy: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3.ZERO)
	var fighter: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(1.5, 0.0, 0.0))
	var bystander: Unit = spawn_unit(&"neutral", 12, 12, 20, [melee()], Vector3(0.0, 0.0, 5.0))

	var roster: Array[Unit] = [enemy, fighter]
	var fight: Encounter = CombatManager.start_combat(roster)
	await get_tree().process_frame
	DetectionManager.scan()

	check("a neutral standing in a fight it has no stake in stays out",
		not fight.turn_order.has(bystander))

	_ensure_out_of_combat()
	await get_tree().process_frame
	free_spawned()


## The fix-up that makes mid-combat insertion safe: whoever is acting must
## still be the one acting afterwards.
func _turn_index_survives_a_join() -> void:
	_ensure_out_of_combat()
	var a: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3.ZERO)
	var b: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(1.5, 0.0, 0.0))
	var c: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3(3.0, 0.0, 0.0))
	var roster: Array[Unit] = [a, b]
	var fight: Encounter = CombatManager.start_combat(roster)
	await get_tree().process_frame

	var acting: Unit = fight.current_unit
	var before: int = fight.turn_order.size()
	CombatManager.add_unit_to_combat(c, a)

	check("joining grows the turn order", fight.turn_order.size() == before + 1)
	check("and current_unit still points at the same combatant",
		fight.current_unit == acting,
		"was %s, now %s" % [
			acting.get_display_name() if acting else "null",
			fight.current_unit.get_display_name() if fight.current_unit else "null"])

	_ensure_out_of_combat()
	await get_tree().process_frame
	free_spawned()


## Break away far enough, with nothing able to see you, and the fight lets
## you go — the same rule BG3 uses, per character.
func _escaping_leaves_the_fight() -> void:
	_ensure_out_of_combat()
	var runner: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3.ZERO)
	# A second enemy who stays. Without one the runner is the last hostile,
	# its escape correctly ends the whole fight, and "did the others stay
	# in" stops being a meaningful question.
	var holds_ground: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3(1.0, 0.0, 0.0))
	var chaser: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(2.0, 0.0, 0.0))
	var roster: Array[Unit] = [runner, holds_ground, chaser]
	var fight: Encounter = CombatManager.start_combat(roster)
	await get_tree().process_frame

	check("everyone starts in the fight", fight.turn_order.has(runner))

	# Well past DISENGAGE_DISTANCE, and out of everyone's line of sight is
	# irrelevant at this range — distance alone should carry it.
	runner.global_position = Vector3(0.0, 0.0, 400.0)
	await get_tree().physics_frame
	runner.encounter._try_disengage(runner)

	check("a combatant that got clean away drops out of the turn order",
		not fight.turn_order.has(runner))
	check("while the ones still fighting stay in",
		fight.turn_order.has(chaser) and fight.turn_order.has(holds_ground))
	check("and the fight carries on without it", fight.is_running)

	_ensure_out_of_combat()
	await get_tree().process_frame
	free_spawned()


## And when the last of a side is gone, the fight is simply over.
func _last_one_out_ends_it() -> void:
	_ensure_out_of_combat()
	var lone_enemy: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3.ZERO)
	var player: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(2.0, 0.0, 0.0))
	var roster: Array[Unit] = [lone_enemy, player]
	var fight: Encounter = CombatManager.start_combat(roster)
	await get_tree().process_frame

	lone_enemy.global_position = Vector3(0.0, 0.0, 400.0)
	await get_tree().physics_frame
	lone_enemy.encounter._try_disengage(lone_enemy)

	check("the fight ends once the last hostile has escaped",
		not fight.is_running)

	_ensure_out_of_combat()
	await get_tree().process_frame
	free_spawned()


## Running away is not the same as making peace.
func _escape_does_not_forgive() -> void:
	_ensure_out_of_combat()
	var runner: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3.ZERO)
	var player: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(2.0, 0.0, 0.0))
	FactionRelations.escalate_to_temporary_hostile(&"enemy", &"player")
	var roster: Array[Unit] = [runner, player]
	CombatManager.start_combat(roster)
	await get_tree().process_frame

	runner.global_position = Vector3(0.0, 0.0, 400.0)
	await get_tree().physics_frame
	# Checked BEFORE the escape ends combat, since combat ending is what
	# legitimately clears temporary hostility (see FactionRelations) — the
	# claim is that LEAVING doesn't clear it, not that it survives forever.
	CombatManager.remove_unit_from_combat(runner)
	check("leaving a fight does not clear the hostility that caused it",
		FactionRelations.is_temporary_hostile(&"enemy", &"player")
			or FactionRelations.is_hostile(&"enemy", &"player"))

	_ensure_out_of_combat()
	await get_tree().process_frame
	free_spawned()


## Clears every running encounter, not just the focused one — a fight left
## running unfocused (from a prior case, or one that never involved the
## player) would previously be invisible to CombatManager.in_combat and
## silently survive into the next case.
func _ensure_out_of_combat() -> void:
	for encounter in CombatManager.encounters.duplicate():
		if is_instance_valid(encounter) and encounter.is_running:
			encounter.finish(&"")
