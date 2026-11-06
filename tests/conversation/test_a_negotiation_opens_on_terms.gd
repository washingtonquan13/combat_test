extends AiTestCase
## Pins how a negotiation begins today: who can be offered it, every way
## a start is refused, and the state a start leaves behind (mood from
## alignment, the rolled gold, a fresh pardon, the order of the opening
## signals). It also pins what an open negotiation locks: saving, travel,
## focus switching and, since the rewrite, a stash too: the stash asks
## GameMode whether input is taken, and a running conversation of any
## kind takes it. Before, only nobody reaching a stash mid-fight kept it
## out.
##
## These are the terms the rewrite's single engine must open on. Dialogue
## refuses a participant who is fighting; negotiation refuses an actor who
## is NOT. A merged "can a conversation start" check that loses that
## asymmetry breaks one of the two.
##
## wants_world(): negotiation is combat-only, and "in combat" means in a
## running encounter, which only a world has. Everything conversational
## goes through conversation_driver.gd.

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
	goblin = spawn_demon("goblin_rogue", Vector3(2, 0, 0))
	fight = d.start_fight([ada, goblin])
	await get_tree().process_frame
	await _give_turn_to(ada)
	check("setup: Ada is fighting the goblin, on her own turn",
		ada.in_combat() and goblin.in_combat() and ada.is_my_turn())

	await _who_can_be_offered_it()
	await _refusals()
	await _start_state()
	await _the_first_satisfied_root_opens()
	await _what_an_open_negotiation_locks()
	await _costs_nothing()

	d.finish()


func _give_turn_to(unit: Unit) -> void:
	var n: int = 0
	while fight.current_unit != unit and n < 10:
		fight.end_turn()
		await get_tree().process_frame
		await get_tree().process_frame
		n += 1


func _refused(label: String) -> void:
	check(label, not d.negotiation_active() and d.event_count("negotiation_started") == 0, str(d.events))


## interaction_offered_gate, negotiable_default_on_unit,
## neg_interact_availability.
func _who_can_be_offered_it() -> void:
	check("every unit carries the Negotiate verb, even the player's own",
		d.offers_negotiate(goblin) and d.offers_negotiate(ada))
	check("negotiable comes from the species", goblin.negotiable == d.species("goblin_rogue").negotiable and goblin.negotiable)
	var pixie: Unit = spawn_demon("test_pixie", Vector3(-3, 0, 0))
	check("and a species that is not negotiable makes a unit that is not", not pixie.negotiable)
	check("offered: in a fight, hostile, negotiable", d.can_negotiate(ada, goblin))
	check("not offered for a unit that is not negotiable", not d.can_negotiate(ada, pixie))
	var rock := Node3D.new()
	check("not offered for something that is not a unit", not d.can_negotiate(ada, rock))
	rock.free()
	var calm: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(0, 0, 6))
	check("not offered to someone who is not in the fight", not d.can_negotiate(calm, goblin))
	goblin.negotiable = false
	check("negotiable is per instance: switching it off withdraws the offer", not d.can_negotiate(ada, goblin))
	goblin.negotiable = true
	var wolf: Unit = spawn_demon("test_wolf", Vector3(-5, 0, 0))
	wolf.negotiable = true
	fight.add_unit(wolf)
	await get_tree().process_frame
	check("the offer does not ask whether the demon has anything to say",
		d.can_negotiate(ada, wolf) and d.species_root_id(wolf.definition, ada) == "")
	d.clear_events()
	d.negotiate(ada, wolf)
	_refused("so a negotiable demon with no negotiation offers it and then does nothing")
	remove_spawned(wolf)
	remove_spawned(pixie)
	remove_spawned(calm)
	await get_tree().process_frame


## neg_start_refusals, start_refuse_actor_not_in_combat,
## start_refuse_already_active, start_refuse_dialogue_or_stash,
## start_refuse_demon_state, start_refuse_no_root.
func _refusals() -> void:
	var bystander: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(0, 0, 8))
	var brom: Unit = spawn_unit(&"neutral", 10, 10, 10, [melee()], Vector3(2, 0, 8))

	d.clear_events()
	d.start_negotiation(bystander, goblin)
	_refused("an actor who is not in a fight is refused, though the demon is in one")

	d.start_dialogue(d.node("n_talk", "Meanwhile.", [d.line("Bye.")]), {"player": bystander, "npc": brom})
	check("setup: a dialogue is open", d.dialogue_active())
	d.clear_events()
	d.start_negotiation(ada, goblin)
	_refused("an open dialogue refuses a negotiation")
	d.end_dialogue()

	var stash := StashComponent.new()
	StashManager.open_stash(stash, bystander)
	check("setup: a stash is open", StashManager.is_active())
	d.clear_events()
	d.start_negotiation(ada, goblin)
	_refused("an open stash refuses a negotiation")
	StashManager.close_stash()
	stash.free()

	var pixie: Unit = spawn_demon("test_pixie", Vector3(-3, 0, 0))
	fight.add_unit(pixie)
	await get_tree().process_frame
	d.clear_events()
	d.start_negotiation(ada, pixie)
	_refused("a demon that is not negotiable is refused")

	var bare: Unit = spawn_unit(&"enemy", 10, 10, 10, [melee()], Vector3(-5, 0, 0))
	fight.add_unit(bare)
	await get_tree().process_frame
	bare.negotiable = true
	d.clear_events()
	d.start_negotiation(ada, bare)
	_refused("a negotiable unit whose species has no negotiation is refused")
	bare.definition = null
	d.clear_events()
	d.start_negotiation(ada, bare)
	_refused("so is a unit with no species at all")

	var doomed: Unit = spawn_demon("goblin_rogue", Vector3(-7, 0, 0))
	fight.add_unit(doomed)
	await get_tree().process_frame
	doomed.take_damage(9999)
	d.clear_events()
	d.start_negotiation(ada, doomed)
	_refused("a dead demon is refused")

	d.clear_events()
	d.start_negotiation(ada, goblin)
	check("setup: the goblin negotiation opens", d.negotiation_active())
	var second: Unit = spawn_demon("goblin_rogue", Vector3(4, 0, 0))
	fight.add_unit(second)
	await get_tree().process_frame
	d.start_negotiation(ada, second)
	check("a second negotiation is refused and the first is untouched",
		d.current_demon() == goblin and d.event_count("negotiation_started") == 1, str(d.events))
	d.end_negotiation("attack")
	await get_tree().process_frame

	for unit in [bystander, brom, pixie, bare, doomed, second]:
		remove_spawned(unit)
	await get_tree().process_frame


## neg_start_state, start_resets_per_negotiation_state,
## start_mood_from_alignment_mismatch, start_gold_roll,
## start_signal_order, is_active_derived, line_raw_text_emitted,
## format_text_gold_token.
func _start_state() -> void:
	var root: DialogueNode = d.node("n_ask", "Pay me {gold}.", [
		d.neg_line("Maybe.", "n_ask", {"repeatable": true}),
		d.disliked("No.", "n_ask"),
		d.neg_outcome("Go away.", "attack")])
	d.register_negotiation([root])
	var def: UnitDefinition = d.species_with_roots("goblin_rogue", [[root, null]])
	var imp: Unit = d.spawn_species(self, def, Vector3(-2, 0, 2))
	fight.add_unit(imp)
	await get_tree().process_frame

	d.start_negotiation(ada, imp)
	await d.choose("Maybe.")
	await d.choose("No.")
	check("setup: a negotiation that used a choice and its pardon",
		d.used_count(true) > 0 and not d.pardon_available())
	d.end_negotiation("attack")

	ada.alignment = 30
	ada.tendency = -30
	imp.alignment = 0
	imp.tendency = 0
	d.clear_events()
	check("setup: a gold roll can be pinned", d.pin_negotiated_gold(def.rank, def.rank * 10 + 7) > 0)
	d.start_negotiation(ada, imp)
	check("the actor and the demon are recorded", d.current_actor() == ada and d.current_demon() == imp)
	check("the used choices are cleared", d.used_count(true) == 0)
	check("the pardon is restored", d.pardon_available())
	check("mood starts at minus the alignment and tendency mismatch: Lawful-Dark vs neutral is -2",
		d.mood() == -2, str(d.mood()))
	check("with no mood note for it", d.event_count("mood_note") == 0)
	check("the gold is rolled from the rank, between rank*10 and rank*20",
		d.negotiated_gold() == def.rank * 10 + 7, str(d.negotiated_gold()))
	check("the order is started, line, choices",
		d.events.size() >= 3 and d.events[0].begins_with("negotiation_started:")
		and d.events[1].begins_with("neg_line:") and d.events[2] == "neg_choices:3", str(d.events))
	check("and the negotiation already counts as open when started fires",
		d.event_state[0].negotiation_active and d.event_state[0].mode == "NEGOTIATION", str(d.event_state[0]))
	check("the line goes out raw, {gold} and all", d.events[1] == "neg_line:Pay me {gold}.", d.events[1])
	check("the gold is filled in only when asked", d.negotiation_text("Pay me {gold}.") == "Pay me %d." % (def.rank * 10 + 7))
	check("and asking never changes the authored text", root.text_block == "Pay me {gold}.")
	check("while open, the game's mode is NEGOTIATION", d.mode() == "NEGOTIATION", d.mode())

	var gold_then: int = d.negotiated_gold()
	await d.choose("Maybe.")
	check("the gold stays put for the rest of the negotiation", d.negotiated_gold() == gold_then)
	d.end_negotiation("attack")
	check("ended mid-fight, the mode goes back to COMBAT", d.mode() == "COMBAT", d.mode())
	ada.alignment = 0
	ada.tendency = 0

	ada.alignment = -30
	imp.alignment = 30
	imp.tendency = 30
	ada.tendency = -30
	d.start_negotiation(ada, imp)
	check("the widest mismatch starts at -4", d.mood() == -4, str(d.mood()))
	d.end_negotiation("attack")
	ada.alignment = 0
	ada.tendency = 0
	remove_spawned(imp)
	await get_tree().process_frame


## root_first_satisfied_option.
func _the_first_satisfied_root_opens() -> void:
	var gated: DialogueNode = d.node("n_gated", "Only if flagged.", [d.neg_outcome("Go.", "attack")])
	var open_a: DialogueNode = d.node("n_open_a", "First open root.", [d.neg_outcome("Go.", "attack")])
	var open_b: DialogueNode = d.node("n_open_b", "Second open root.", [d.neg_outcome("Go.", "attack")])
	d.register_negotiation([gated, open_a, open_b])
	FlagManager.clear_flag("conv_neg_gate")
	var def: UnitDefinition = d.species_with_roots("goblin_rogue",
		[[gated, d.needs_flag("conv_neg_gate")], [open_a, null], [open_b, null]])
	var imp: Unit = d.spawn_species(self, def, Vector3(-2, 0, 2))
	fight.add_unit(imp)
	await get_tree().process_frame

	d.clear_events()
	d.start_negotiation(ada, imp)
	check("the first root whose condition holds opens: an unmet one is skipped",
		d.current_node_id() == "n_open_a" and d.events[1] == "neg_line:First open root.", str(d.events))
	d.end_negotiation("attack")
	FlagManager.set_flag("conv_neg_gate")
	d.start_negotiation(ada, imp)
	check("and once it holds, the earlier root wins", d.current_node_id() == "n_gated")
	d.end_negotiation("attack")

	# The root is chosen inside the conversation about to begin, whose cast
	# is the actor as "player" and the demon as "npc", so a presence gate
	# on either holds, the same as it would in any of the tree's own gates.
	var with_npc: DialogueNode = d.node("n_with_npc", "You and I, then.", [d.neg_outcome("Go.", "attack")])
	d.register_negotiation([with_npc])
	var present_def: UnitDefinition = d.species_with_roots("goblin_rogue",
		[[with_npc, d.needs_participant("npc")], [open_a, null]])
	var imp2: Unit = d.spawn_species(self, present_def, Vector3(-3, 0, 3))
	fight.add_unit(imp2)
	await get_tree().process_frame
	d.start_negotiation(ada, imp2)
	check("a root gated on the demon being present opens: in a negotiation the demon is the npc",
		d.current_node_id() == "n_with_npc", d.current_node_id())
	check("and inside it, both sides count as present",
		d.satisfied(d.needs_participant("npc"), ada) and d.satisfied(d.needs_participant("player"), ada))
	d.end_negotiation("attack")
	remove_spawned(imp2)
	await get_tree().process_frame

	var real_root: String = d.species_root_id(d.species("goblin_rogue"), ada)
	d.clear_events()
	d.start_negotiation(ada, goblin)
	check("a real goblin opens on its personality's greeting",
		real_root != "" and d.current_node_id() == real_root
		and d.events[1] == "neg_line:" + d.negotiation_node(real_root).text, str(d.events))
	d.end_negotiation("attack")
	remove_spawned(imp)
	await get_tree().process_frame


## blocks_save_and_travel, blocks_stash_open, neg_music, music_negotiation
## (start half; the end half is in test_every_negotiation_ends_somewhere).
func _what_an_open_negotiation_locks() -> void:
	var travellers: Array[Unit] = [ada]
	check("setup: in a fight alone, saving is allowed", SaveManager.can_save())
	d.forget_music_requests()
	d.start_negotiation(ada, goblin)
	check("an open negotiation asks for the area's negotiation music", d.music_was_requested("negotiation"))
	check("an open negotiation refuses a save", not SaveManager.can_save())
	check("refuses travel", not WorldManager.can_travel(travellers))
	check("and refuses switching focus", not WorldManager.can_switch_focus())
	var stash := StashComponent.new()
	var bystander: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(0, 0, 8))
	StashManager.open_stash(stash, bystander)
	# Changed by the rewrite: the stash's one question, whether input is
	# taken, now sees the negotiation as it always saw a dialogue.
	check("and refuses a stash", not StashManager.is_active())
	if StashManager.is_active():
		StashManager.close_stash()
	stash.free()
	remove_spawned(bystander)
	d.forget_music_requests()
	d.end_negotiation("attack")
	check("ending it while the fight goes on asks for the combat music again", d.music_was_requested("combat"))
	check("and saving is allowed again", SaveManager.can_save())


## interaction_execute_starts, no_action_cost_or_turn_check.
func _costs_nothing() -> void:
	var cato: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(-1, 0, 1))
	fight.add_unit(cato)
	await get_tree().process_frame
	check("setup: it is not Cato's turn", not cato.is_my_turn())
	var moves: float = cato.move_remaining
	var attacked: bool = cato.has_attacked
	d.negotiate(cato, goblin)
	check("Negotiate starts a negotiation off the actor's turn", d.negotiation_active() and d.current_actor() == cato)
	check("and spends neither move nor attack", cato.move_remaining == moves and cato.has_attacked == attacked)
	d.end_negotiation("attack")
	remove_spawned(cato)
	await get_tree().process_frame
