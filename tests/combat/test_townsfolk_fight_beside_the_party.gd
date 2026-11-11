extends AiTestCase
## The Town Watchman in the goblin camp ambush: townsfolk are on the
## party's side, a loaded save does not undo that, and a fight with the
## party, the town and the goblins in it ends once the goblins are dead.


func run() -> void:
	_saved_ai_factions = CombatAi.ai_factions.duplicate()
	# CombatAI off: the fight is ended by hand, and an AI turn walking units
	# around while this case frees them is not what is under test.
	CombatAi.ai_factions = [] as Array[StringName]

	_a_save_keeps_the_town_allied()
	_the_fight_ends_with_the_goblins()

	CombatAi.ai_factions = _saved_ai_factions


var _saved_ai_factions: Array[StringName] = []


## A save written before the seed existed has no townsfolk pair at all.
## Loading it must leave the authored relation in place, not reset it.
func _a_save_keeps_the_town_allied() -> void:
	var saved: Dictionary = FactionRelations.save_state()
	FactionRelations.load_state({"base": {}})
	check("townsfolk and the party are not hostile after a load",
		not FactionRelations.is_hostile(&"townsfolk", Unit.PLAYER_FACTION))
	check("and townsfolk still fight the goblins",
		FactionRelations.is_hostile(&"townsfolk", &"enemy"))
	FactionRelations.load_state(saved)


func _the_fight_ends_with_the_goblins() -> void:
	var hero: Unit = spawn_unit(&"player", 10, 12, 20, [melee()], Vector3.ZERO)
	var watchman: Unit = spawn_unit(&"townsfolk", 10, 12, 20, [melee()], Vector3(2.0, 0.0, 0.0))
	var goblin: Unit = spawn_unit(&"enemy", 10, 12, 20, [melee()], Vector3(0.0, 0.0, -3.0))
	var roster: Array[Unit] = [hero, watchman, goblin]
	var fight: Encounter = CombatManager.start_combat(roster)

	check("all three are in the fight", fight != null
		and fight.turn_order.has(hero) and fight.turn_order.has(watchman)
		and fight.turn_order.has(goblin))
	goblin.take_damage(5000)
	check("the fight ends when the goblin dies, with the watchman still standing",
		not fight.is_running and watchman.is_alive() and not watchman.in_combat())

	if fight.is_running:
		fight.finish(&"")
	free_spawned()
