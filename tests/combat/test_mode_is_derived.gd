extends AiTestCase
## The game mode is computed from live state, and nothing sets it.
##
## GameMode used to be an imperative stack with two writers that had no
## contract between them: WorldManager replaced the whole stack on every
## world focus, while CombatManager pushed and popped against its own
## mirrored _combat_mode_depth counter. Three copies of one fact, free to
## disagree — and they did, every run, printing "GameMode.pop_mode
## refused: nothing to pop" through a green suite.
##
## What is asserted here is the BEHAVIOUR that survived the rewrite, not
## the mechanism. In particular the last two checks pin the one property
## the stack existed to provide, and the one most likely to be lost by
## deriving: leaving a modal that was opened during a fight must return to
## COMBAT, not fall through to whatever the base mode is. A derived mode
## gets that right for a different reason than a stack did — there is
## nothing to restore, because the fight underneath never stopped being
## true — but "right for a different reason" still has to be demonstrated.
##
## wants_world(): true. base_mode() asks WorldManager.current_world() for
## get_base_mode() once a world is loaded (see game_mode.gd's own header),
## and only falls through to the front-end/MAIN_MENU branch with none
## loaded. With the fixture loaded that branch is no longer reachable —
## base_mode() reads the fixture's own get_base_mode(), which
## test_world_area.gd does not override, so it inherits GameArea's
## default: EXPLORATION, the same answer every real area in the game
## gives. THIS IS A LEGITIMATE CORRECTION, not a loosened assertion: the
## suite used to run the bare-harness fallback exclusively — the same one
## the real title screen uses — and never exercised the branch every
## actual area actually takes. _the_floor_is_main_menu (name kept for its
## history; it now asserts EXPLORATION — see its own comment) and the two
## "falls back to the base mode" checks in _a_watched_fight_reads_as_combat
## and _leaving_the_modal_returns_to_the_fight are the three updated for
## it. Check COUNT is unchanged (8): every check that ran before still
## runs, against the corrected expected value.


func run() -> void:
	_the_floor_is_main_menu()
	await _a_watched_fight_reads_as_combat()
	await _a_modal_over_a_fight_wins()
	await _leaving_the_modal_returns_to_the_fight()


func wants_world() -> bool:
	return true


## With the fixture loaded, base_mode() reads the WORLD's own
## get_base_mode() rather than falling through to the front-end/MAIN_MENU
## branch — that branch is what a no-world state means, and a loaded world
## is never in that state. The fixture doesn't override get_base_mode(),
## so it inherits GameArea's default: EXPLORATION. Name kept for the
## check's shape and history; the value is the corrected one (see this
## file's header).
func _the_floor_is_main_menu() -> void:
	check("with a world loaded and nothing open the mode is EXPLORATION",
		GameMode.current_mode() == GameMode.Mode.EXPLORATION,
		"read %s" % GameMode.Mode.keys()[GameMode.current_mode()])
	check("and nothing is overlaid on it",
		GameMode.can_transition())


func _a_watched_fight_reads_as_combat() -> void:
	var ally: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3.ZERO)
	var foe: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3(1.5, 0.0, 0.0))
	var fight: Encounter = CombatManager.start_combat([ally, foe] as Array[Unit])
	await get_tree().process_frame

	check("a running fight the player is in reads as COMBAT",
		GameMode.current_mode() == GameMode.Mode.COMBAT,
		"read %s" % GameMode.Mode.keys()[GameMode.current_mode()])
	check("and a transition is refused while it runs",
		not GameMode.can_transition())

	if is_instance_valid(fight) and fight.is_running:
		fight.finish(&"")
	await get_tree().process_frame

	check("and the mode drops back once it ends",
		GameMode.current_mode() == GameMode.Mode.EXPLORATION,
		"read %s" % GameMode.Mode.keys()[GameMode.current_mode()])
	free_spawned()


## A modal the player is INSIDE outranks the fight going on around them.
## Asserted with a stash because it is the cheapest modal to stand up;
## the rule is about the precedence order in current_mode(), not about
## looting specifically.
func _a_modal_over_a_fight_wins() -> void:
	var ally: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3.ZERO)
	var foe: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3(1.5, 0.0, 0.0))
	var fight: Encounter = CombatManager.start_combat([ally, foe] as Array[Unit])
	await get_tree().process_frame

	# The real scene, not StashComponent.new(): the component's @onready
	# names an Inventory child it does not build for itself, and a
	# hand-made one errors twice on every open. Suite noise is what hid
	# two false greens while this phase was being written.
	var stash: StashComponent = preload("res://systems/inventory_system/stash_component.tscn").instantiate()
	_root.add_child(stash)
	StashManager.open_stash(stash, ally)
	await get_tree().process_frame

	check("a modal opened during a fight outranks it",
		GameMode.current_mode() == GameMode.Mode.LOOTING,
		"read %s" % GameMode.Mode.keys()[GameMode.current_mode()])

	StashManager.close_stash()
	if is_instance_valid(fight) and fight.is_running:
		fight.finish(&"")
	await get_tree().process_frame
	stash.queue_free()
	free_spawned()


## The property the stack was built for, stated in its own words by the
## old GameMode header: "leaving a negotiation started mid-combat must
## return to COMBAT, not silently drop to EXPLORATION." Negotiation needs
## a full demon definition to start, so the same shape is proved with the
## modal that stands up cheapest — what is under test is the fall-back,
## not which modal it was.
func _leaving_the_modal_returns_to_the_fight() -> void:
	var ally: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3.ZERO)
	var foe: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3(1.5, 0.0, 0.0))
	var fight: Encounter = CombatManager.start_combat([ally, foe] as Array[Unit])
	await get_tree().process_frame

	# The real scene, not StashComponent.new(): the component's @onready
	# names an Inventory child it does not build for itself, and a
	# hand-made one errors twice on every open. Suite noise is what hid
	# two false greens while this phase was being written.
	var stash: StashComponent = preload("res://systems/inventory_system/stash_component.tscn").instantiate()
	_root.add_child(stash)
	StashManager.open_stash(stash, ally)
	await get_tree().process_frame
	if GameMode.current_mode() != GameMode.Mode.LOOTING:
		check("SETUP: the modal opened over the fight", false,
			"read %s" % GameMode.Mode.keys()[GameMode.current_mode()])
		StashManager.close_stash()
		if is_instance_valid(fight) and fight.is_running:
			fight.finish(&"")
		stash.queue_free()
		free_spawned()
		return

	StashManager.close_stash()
	await get_tree().process_frame

	check("closing it returns to the fight, not to the base mode",
		GameMode.current_mode() == GameMode.Mode.COMBAT,
		"read %s — dropping to the base mode here is the exact failure the old mode STACK existed to prevent" % GameMode.Mode.keys()[GameMode.current_mode()])

	if is_instance_valid(fight) and fight.is_running:
		fight.finish(&"")
	await get_tree().process_frame

	check("and only then does it fall back to the base mode",
		GameMode.current_mode() == GameMode.Mode.EXPLORATION,
		"read %s" % GameMode.Mode.keys()[GameMode.current_mode()])

	stash.queue_free()
	free_spawned()
