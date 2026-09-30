extends AiTestCase
## Pins how every negotiation ends today and what each ending leaves
## behind: the recruit/heal roll and its FLEE fallback, the roster entry,
## the healed actor, the demon that expires (and can end the fight while
## the negotiation is still technically open), the ATTACK ending's free
## strike that turn order usually refuses, and the state that survives
## the end.
##
## An ending is where negotiation reaches into four other systems at once
## (DemonRoster, HP, the encounter, the music). A rewrite that routes
## endings through a shared "conversation ended" path has to keep each
## of these side effects, and keep their ORDER: combat_ended arrives
## before negotiation_ended when the demon was the last hostile.
##
## wants_world(): endings expire units out of running encounters. Rolls
## are pinned through the driver, on the conversation's own dice. The goblin anchors the main
## fight; the last section stops it to watch a fight end with the
## negotiation. Everything conversational goes through conversation_driver.gd.

const Driver := preload("res://tests/conversation/conversation_driver.gd")

var d: Driver
var ada: Unit
var goblin: Unit
var fight: Encounter


func wants_world() -> bool:
	return true


func run() -> void:
	d = Driver.new()
	add_child(d)
	d.begin()
	ada = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(0, 0, 0))
	ada.display_name = "Ada"
	goblin = spawn_demon("goblin_rogue", Vector3(3, 0, 0))
	fight = d.start_fight([ada, goblin])
	await get_tree().process_frame
	await _give_turn_to(ada)
	check("setup: Ada's turn in a running fight", ada.is_my_turn())

	_the_roll()
	await _recruit()
	await _recruit_can_fail_after_paying()
	await _heal()
	await _flee_and_expire()
	await _attack_off_turn()
	await _attack_on_the_demons_turn()
	await _what_survives_the_end()
	await _a_dying_demon_is_not_noticed()
	await _the_last_hostile_leaves()

	d.finish()


func _give_turn_to(unit: Unit) -> void:
	var n: int = 0
	while fight.current_unit != unit and n < 10:
		fight.end_turn()
		await get_tree().process_frame
		await get_tree().process_frame
		n += 1


func _demon_on(root: DialogueNode, at: Vector3 = Vector3(-2, 0, 2), encounter: Encounter = null) -> Unit:
	var imp: Unit = d.spawn_species(self, d.species_with_roots("goblin_rogue", [[root, null]]), at)
	imp.display_name = "Imp"
	(encounter if encounter else fight).add_unit(imp)
	await get_tree().process_frame
	return imp


func _gone(unit: Unit) -> bool:
	return not is_instance_valid(unit) or not unit.is_alive()


func _tidy(unit: Unit) -> void:
	if is_instance_valid(unit):
		remove_spawned(unit)
	await get_tree().process_frame


## roll_success_formula.
## The roll draws from the conversation's own dice, never the global
## generator, so the same seed in a twin generator predicts it exactly.
func _the_roll() -> void:
	var agrees: bool = true
	var detail: String = ""
	for mood in [-10, -5, -1, 0, 2, 4, 10]:
		var chance: float = clampf(0.5 + mood * 0.1, 0.05, 0.95)
		for s in range(1, 40):
			var twin := RandomNumberGenerator.new()
			twin.seed = s
			var draw: float = twin.randf()
			if d.roll_outcome(mood, s) != (draw < chance):
				agrees = false
				detail = "mood %d seed %d" % [mood, s]
	check("the outcome roll succeeds on one randf() of the conversation's dice below clamp(0.5 + mood/10, 0.05, 0.95)",
		agrees, detail)


## end_recruit, neg_outcome_roll, recruit_heal_chance_gated,
## neg_end_outcomes (recruit), no_dice_or_assist.
func _recruit() -> void:
	var root: DialogueNode = d.node("r_root", "Well?", [d.neg_outcome("Join me.", "recruit")])
	d.register_negotiation([root])
	var imp: Unit = await _demon_on(root)
	var cato: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(-1, 0, -1))
	fight.add_unit(cato)
	imp.take_damage(3)
	var owned_before: int = DemonRoster.all_owned().size()
	d.hold_dice()
	d.start_negotiation(ada, imp)
	d.clear_events()
	d.pin_outcome_roll(true)
	await d.choose("Join me.")
	check("a winning roll recruits", d.events.has("negotiation_ended:RECRUIT"), str(d.events))
	var owned: Array = DemonRoster.all_owned()
	check("the roster gains one of the species, at the species' full HP, not the unit's",
		owned.size() == owned_before + 1 and owned.back().species == imp.definition
		and owned.back().current_hp == imp.definition.max_hp, str(owned.size()))
	check("logged as joining, then fading", d.log_has("Imp joins your demon roster.") and d.log_has("Imp fades away.")
		and d.log_lines().find("Imp joins your demon roster.") < d.log_lines().find("Imp fades away."), str(d.log_lines()))
	await get_tree().process_frame
	check("and the unit leaves the field", _gone(imp))
	check("no dice are ever asked for, and no companion helps", d.dice_requests.is_empty())
	d.release_dice()
	await _tidy(imp)
	remove_spawned(cato)
	await get_tree().process_frame


## gold_spent_even_if_recruit_fails, recruit_heal_chance_gated (failure).
func _recruit_can_fail_after_paying() -> void:
	var root: DialogueNode = d.node("rf_root", "Pay?", [d.neg_outcome("Take {gold}.", "recruit",
		{"effects": [d.negotiated_gold_cost()]})])
	d.register_negotiation([root])
	var imp: Unit = await _demon_on(root)
	var owned_before: int = DemonRoster.all_owned().size()
	d.start_negotiation(ada, imp)
	var price: int = d.negotiated_gold()
	var purse: int = CurrencyManager.gold
	CurrencyManager.gold = price + 10
	d.clear_events()
	d.pin_outcome_roll(false)
	await d.choose("Take {gold}.")
	check("a losing roll turns the recruit into a FLEE", d.events.back() == "negotiation_ended:FLEE", str(d.events))
	check("saying so", d.log_has("Despite everything, the demon hesitates and backs away."))
	check("the gold was paid anyway", CurrencyManager.gold == 10, str(CurrencyManager.gold))
	check("and nobody joins", DemonRoster.all_owned().size() == owned_before)
	await get_tree().process_frame
	check("the demon leaves", _gone(imp))
	CurrencyManager.gold = purse
	await _tidy(imp)


## end_heal_player, neg_end_outcomes (heal).
func _heal() -> void:
	var root: DialogueNode = d.node("hl_root", "Hurt?", [d.neg_outcome("Heal me.", "heal")])
	d.register_negotiation([root])
	var imp: Unit = await _demon_on(root)
	ada.current_hp = 3
	d.start_negotiation(ada, imp)
	d.clear_events()
	d.pin_outcome_roll(false)
	await d.choose("Heal me.")
	check("a losing heal roll is a FLEE and heals nothing",
		d.events.back() == "negotiation_ended:FLEE" and ada.current_hp == 3, str(d.events))
	await _tidy(imp)

	imp = await _demon_on(root)
	d.start_negotiation(ada, imp)
	d.clear_events()
	d.pin_outcome_roll(true)
	await d.choose("Heal me.")
	check("a winning one heals the actor to full", d.events.back() == "negotiation_ended:HEAL" and ada.current_hp == ada.maximum_hp,
		"%s hp %d" % [str(d.events), ada.current_hp])
	check("logged", d.log_has("Imp heals Ada and departs peacefully."), str(d.log_lines()))
	await get_tree().process_frame
	check("and the demon departs", _gone(imp))
	await _tidy(imp)


## end_flee, expire_side_effects.
func _flee_and_expire() -> void:
	var root: DialogueNode = d.node("fl_root", "Hm.", [d.neg_outcome("Leave.", "flee")])
	d.register_negotiation([root])
	var imp: Unit = await _demon_on(root)
	var deaths: Array = []
	imp.died.connect(func(u): deaths.append(u))
	d.start_negotiation(ada, imp)
	d.clear_events()
	await d.choose("Leave.")
	check("FLEE is never rolled", d.events.back() == "negotiation_ended:FLEE")
	check("it logs the flight, then the fade",
		d.log_lines().find("Imp breaks off and flees.") >= 0
		and d.log_lines().find("Imp breaks off and flees.") < d.log_lines().find("Imp fades away."), str(d.log_lines()))
	check("expiring zeroes HP and says died", deaths.size() >= 1 and (not is_instance_valid(imp) or imp.current_hp == 0))
	check("and takes it out of the fight", not is_instance_valid(imp) or not imp.in_combat() or not imp.is_alive())
	await _tidy(imp)


## end_attack_log_and_strike, attack_strike_blocked_off_turn.
func _attack_off_turn() -> void:
	var root: DialogueNode = d.node("at_root", "Grr.", [d.neg_outcome("Fight me.", "attack")])
	d.register_negotiation([root])
	var imp: Unit = await _demon_on(root, ada.global_position + Vector3(0, 0, 1))
	check("setup: Ada's turn, not the demon's, and it is in reach",
		ada.is_my_turn() and not imp.is_my_turn() and imp.default_ability().is_in_range(imp, ada))
	var hp: int = ada.current_hp
	d.start_negotiation(ada, imp)
	d.clear_events()
	await d.choose("Fight me.")
	await get_tree().process_frame
	check("ATTACK is logged as a trick", d.log_has("Imp was a trick — it attacks!"), str(d.log_lines()))
	check("the free strike goes through turn order, so off its turn it does nothing", ada.current_hp == hp)
	check("the demon stays in the fight", imp.is_alive() and imp.in_combat())
	await _tidy(imp)


## neg_free_strike_while_active.
func _attack_on_the_demons_turn() -> void:
	var root: DialogueNode = d.node("at2_root", "Grr.", [d.neg_outcome("Fight me.", "attack")])
	d.register_negotiation([root])
	var imp: Unit = await _demon_on(root, ada.global_position + Vector3(0, 0, 1))
	await _give_turn_to(imp)
	check("setup: the demon's own turn, beside Ada", imp.is_my_turn() and imp.default_ability().is_in_range(imp, ada))
	var seen: Array = []
	imp.ability_use_started.connect(func(_a, _t, _ab): seen.append([d.negotiation_active(), d.mode()]))
	d.start_negotiation(ada, imp)
	await d.choose("Fight me.")
	check("on its turn the strike is really swung, while the negotiation still counts as open",
		seen.size() == 1 and seen[0][0] == true and seen[0][1] == "NEGOTIATION", str(seen))
	check("and it is over once the choice returns", not d.negotiation_active())
	await _give_turn_to(ada)
	check("setup: back to Ada", ada.is_my_turn())
	ada.current_hp = ada.maximum_hp
	await _tidy(imp)


## neg_end_cleanup, end_cleanup_then_signal, end_refuses_continue_or_idle.
func _what_survives_the_end() -> void:
	var root: DialogueNode = d.node("sv_root", "So.", [d.neg_line("Hm.", "sv_root"),
		d.disliked("Tch.", "sv_root"), d.neg_outcome("Bye.", "attack")])
	d.register_negotiation([root])
	var imp: Unit = await _demon_on(root)
	d.start_negotiation(ada, imp)
	await d.choose("Hm.")
	await d.choose("Tch.")
	d.set_mood(3)
	var gold: int = d.negotiated_gold()
	d.clear_events()
	d.end_negotiation("continue")
	check("ending with CONTINUE does nothing", d.negotiation_active() and d.events.is_empty(), str(d.events))
	d.end_negotiation("attack")
	check("an ending clears the actor, the demon and the node",
		not d.negotiation_active() and d.current_actor() == null and d.current_demon() == null)
	check("and it is already closed when negotiation_ended goes out",
		d.event_state[d.event_index("negotiation_ended")].negotiation_active == false)
	check("mood, gold, used choices and the spent pardon outlive it",
		d.mood() == 3 and d.negotiated_gold() == gold and d.used_count(true) == 2 and not d.pardon_available())
	d.clear_events()
	d.end_negotiation("flee")
	check("ending with nothing open does nothing", d.events.is_empty(), str(d.events))
	await _tidy(imp)


## demon_death_unwatched.
func _a_dying_demon_is_not_noticed() -> void:
	var root: DialogueNode = d.node("dd_root", "Ow.", [d.neg_outcome("Bye.", "attack")])
	d.register_negotiation([root])
	var imp: Unit = await _demon_on(root)
	d.start_negotiation(ada, imp)
	d.clear_events()
	imp.take_damage(9999)
	check("the demon dying mid-negotiation does not end it",
		not imp.is_alive() and d.negotiation_active() and d.current_demon() == imp and not d.events.has("negotiation_ended:FLEE"),
		str(d.events))
	d.end_negotiation("attack")
	await _tidy(imp)


## combat_end_before_negotiation_ended, music_negotiation (end half).
func _the_last_hostile_leaves() -> void:
	d.stop_fights()
	await get_tree().process_frame
	var eve: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(30, 0, 0))
	var root: DialogueNode = d.node("lh_root", "Last one.", [d.neg_outcome("Go.", "flee")])
	d.register_negotiation([root])
	var imp: Unit = d.spawn_species(self, d.species_with_roots("goblin_rogue", [[root, null]]), Vector3(33, 0, 0))
	var lone: Encounter = d.start_fight([eve, imp])
	await get_tree().process_frame
	check("setup: a fight with one hostile, and no other fight", lone.is_running and CombatManager.all_encounters().filter(
		func(e): return is_instance_valid(e) and e.is_running).size() == 1)
	d.start_negotiation(eve, imp)
	d.clear_events()
	d.forget_music_requests()
	await d.choose("Go.")
	var fight_end: int = d.event_index("combat_ended")
	var talk_end: int = d.event_index("negotiation_ended")
	check("the demon leaving ends the fight, BEFORE the negotiation reports its end",
		fight_end >= 0 and talk_end > fight_end, str(d.events))
	check("while the negotiation still counts as open", d.event_state[fight_end].negotiation_active if fight_end >= 0 else false)
	check("with no fight left, the end does not ask for combat music", not d.music_was_requested("combat"))
	check("the fight's own end asks for exploration", d.music_was_requested("exploration"))
	await _tidy(imp)
	remove_spawned(eve)
	await get_tree().process_frame
