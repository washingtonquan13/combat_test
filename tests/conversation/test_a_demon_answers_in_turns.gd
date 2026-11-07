extends AiTestCase
## Pins how a negotiation walks its tree today, answer by answer: which
## choices a node shows (and when that is decided), how a picked row maps
## to the choice that fires, what a choice writes and in what order, how
## mood moves and is announced, the one pardon, the hated answer, and
## every dead end that fails safe to FLEE.
##
## Negotiation looks like dialogue but differs in ways a merged engine
## will be tempted to flatten: every visit re-shows the demon's line
## (dialogue narrates a node once), a dead end is a FLEE and not a quiet
## end, and node ids live in their own namespace. Each of those is pinned
## here so flattening one shows up as a red check, not a changed game.
## The rewrite knowingly changed two pins: a negotiation now keeps a
## transcript like any conversation, the demon's own lines included as
## narration (only what the player's side says is echoed to SystemLog, so
## the log reads as before), and a dead-end node flees before its line is
## shown, whether it is the root or one reached mid-tree.
##
## wants_world(): a negotiation only runs inside a fight. The goblin
## anchors the fight so it never ends underneath the suite; every demon
## that is expected to leave (FLEE expires it) is a fresh one. It stays
## Ada's turn throughout, so an ATTACK ending's free strike is refused by
## turn order and never changes HP. Everything conversational goes
## through conversation_driver.gd.

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
	var n: int = 0
	while fight.current_unit != ada and n < 10:
		fight.end_turn()
		await get_tree().process_frame
		await get_tree().process_frame
		n += 1
	check("setup: Ada's turn in a running fight", ada.is_my_turn())

	await _every_visit_is_shown()
	await _guards()
	await _filters_are_decided_at_show()
	await _bookkeeping_order()
	await _mood_notes()
	await _volatile()
	await _one_pardon()
	await _hated_is_a_fight()
	await _dead_ends_flee()
	await _a_lethal_price_ends_it()

	d.finish()


## A fresh demon of a copied species whose negotiation opens on `root`,
## already in the fight.
func _demon_on(root: DialogueNode, at: Vector3 = Vector3(-2, 0, 2)) -> Unit:
	var imp: Unit = d.spawn_species(self, d.species_with_roots("goblin_rogue", [[root, null]]), at)
	fight.add_unit(imp)
	await get_tree().process_frame
	return imp


func _gone(unit: Unit) -> bool:
	return not is_instance_valid(unit) or not unit.is_alive()


func _tidy(unit: Unit) -> void:
	if is_instance_valid(unit):
		remove_spawned(unit)
	await get_tree().process_frame


## neg_show_node, line_choice_moves, choice_filter_used,
## choose_visible_index_mapping, neg_choose_mapping,
## choose_marks_before_resolve, choose_stops_if_ended_inside_resolve,
## outcome_choice_ends (the authored outcome half).
func _every_visit_is_shown() -> void:
	var root: DialogueNode = d.node("m_root", "Speak.", [
		d.neg_line("First.", "m_root"), d.neg_line("Second.", "m_side"), d.neg_outcome("Enough.", "attack"),
		d.neg_line("Again.", "m_root", {"repeatable": true})])
	var side: DialogueNode = d.node("m_side", "Aside.", [d.neg_line("Back.", "m_root")])
	d.register_negotiation([root, side])
	var imp: Unit = await _demon_on(root)
	d.clear_events()
	d.start_negotiation(ada, imp)
	check("the root shows all four", d.choices() == PackedStringArray(["First.", "Second.", "Enough.", "Again."]),
		str(d.choices()))
	await d.choose("First.")
	check("a line choice moves to its next node, here the same one, and shows the line again",
		d.event_count("neg_line:Speak.") == 2, str(d.events))
	check("the picked choice is hidden on the return", d.choices() == PackedStringArray(["Second.", "Enough.", "Again."]),
		str(d.choices()))
	await d.choose("Again.")
	await d.choose("Again.")
	check("a repeatable one stays", d.choices().has("Again.") and d.event_count("neg_line:Speak.") == 4)
	await d.choose_row(0)
	check("row 0 is now Second., authored index 1, and it moves to its node",
		d.current_node_id() == "m_side", d.current_node_id())
	check("used choices are keyed by authored index, not row",
		d.was_used("m_root", 1, true) and d.was_used("m_root", 0, true) and not d.was_used("m_root", 2, true))
	await d.choose("Back.")
	check("a node reached again is shown again, every time", d.event_count("neg_line:Speak.") == 5)
	d.clear_events()
	await d.choose("Enough.")
	check("an outcome choice ends the negotiation with its outcome",
		not d.negotiation_active() and d.events.has("negotiation_ended:ATTACK"), str(d.events))
	check("it was marked used before it resolved", d.was_used("m_root", 2, true))
	check("and nothing is shown after the ending",
		d.events.size() == 1 or d.events.slice(d.event_index("negotiation_ended")).all(
			func(e): return not e.begins_with("neg_line") and not e.begins_with("neg_choices")), str(d.events))
	check("the demon of an ATTACK ending stays in the fight", imp.is_alive() and imp.in_combat())
	await _tidy(imp)


## choose_guards.
func _guards() -> void:
	var root: DialogueNode = d.node("g_root", "Well?", [d.neg_line("Hm.", "g_root", {"repeatable": true}),
		d.neg_outcome("Bye.", "attack")])
	d.register_negotiation([root])
	var imp: Unit = await _demon_on(root)
	d.start_negotiation(ada, imp)
	d.clear_events()
	await d.choose_row_in(true, -1)
	await d.choose_row_in(true, 2)
	check("a row outside the shown list does nothing", d.events.is_empty() and d.used_count(true) == 0, str(d.events))
	d.end_negotiation("attack")
	d.clear_events()
	await d.choose_row_in(true, 0)
	check("choosing with nothing open does nothing", d.events.is_empty(), str(d.events))
	await _tidy(imp)


## choice_filter_prereq, choice_filter_evaluated_at_show, mood_prereq,
## negotiated_gold_prereq, sacrifice_negotiated_gold,
## neg_gold_token_and_cost (the manager half).
func _filters_are_decided_at_show() -> void:
	var root: DialogueNode = d.node("f_root", "Terms?", [
		d.neg_outcome("Pay {gold}.", "attack", {"requires": d.needs_negotiated_gold(),
			"effects": [d.negotiated_gold_cost()]}),
		d.neg_line("Flatter.", "f_root", {"requires": d.needs_mood(2), "repeatable": true}),
		d.neg_line("Pay anyway.", "f_root", {"effects": [d.negotiated_gold_cost()], "repeatable": true}),
		d.neg_line("Wait.", "f_root", {"repeatable": true}),
		d.neg_outcome("Bye.", "attack")])
	d.register_negotiation([root])
	var imp: Unit = await _demon_on(root)
	CurrencyManager.gold = 0
	d.start_negotiation(ada, imp)
	var price: int = d.negotiated_gold()
	check("setup: a price was rolled and mood is 0", price > 0 and d.mood() == 0, "%d %d" % [price, d.mood()])
	check("without the gold, the pay choice is hidden; below the mood, the flattery is",
		d.choices() == PackedStringArray(["Pay anyway.", "Wait.", "Bye."]), str(d.choices()))

	CurrencyManager.gold = price
	d.set_mood(2)
	check("the conditions now hold", d.satisfied(d.needs_negotiated_gold(), ada) and d.satisfied(d.needs_mood(2), ada))
	check("but what is shown was decided when the node was shown", not d.choices().has("Pay {gold}."))
	await d.choose("Wait.")
	check("the next showing re-decides: both appear",
		d.choices().has("Pay {gold}.") and d.choices().has("Flatter."), str(d.choices()))
	check("the mood condition reads the running mood, not the unit",
		d.satisfied(d.needs_mood(2), goblin) and not d.satisfied(d.needs_mood(3), ada))

	check("the pay choice is tagged with the rolled price",
		d.cost_tags_of([d.negotiated_gold_cost()]) == PackedStringArray(["-%d gold" % price]))
	CurrencyManager.gold = price - 1
	await d.choose("Pay anyway.")
	check("paying without enough gold silently takes nothing and goes on",
		CurrencyManager.gold == price - 1 and d.negotiation_active() and d.current_node_id() == "f_root")
	CurrencyManager.gold = price + 5
	await d.choose("Wait.")
	await d.choose("Pay {gold}.")
	check("paying with enough takes exactly the price", CurrencyManager.gold == 5, str(CurrencyManager.gold))
	d.set_negotiated_gold(0)
	check("a price of 0 has no tag", d.cost_tags_of([d.negotiated_gold_cost()]).is_empty())
	await _tidy(imp)


## resolve_bookkeeping_order, neg_choice_resolve_syslog, no_transcript,
## shift_mood_effect.
func _bookkeeping_order() -> void:
	var flag: String = "conv_neg_bookkeeping"
	FlagManager.clear_flag(flag)
	var root: DialogueNode = d.node("b_root", "The demon eyes you.", [
		d.neg_line("A fair offer.", "b_root", {"alignment": "Lawful", "flag": flag, "spoken": "Deal, then.",
			"effects": [d.mood_effect(1), d.mood_effect(3)]}),
		d.neg_outcome("Bye.", "attack")])
	d.register_negotiation([root])
	var imp: Unit = await _demon_on(root)
	var said: int = d.transcript().size()
	var start_alignment: int = ada.alignment
	d.clear_events()
	d.start_negotiation(ada, imp)
	# The opening line is narrated into the transcript as the negotiation
	# begins; the panel shows it, so the log must not repeat it.
	check("the demon's opening line is not logged", not d.log_has("The demon eyes you."), str(d.log_lines()))
	d.clear_events()
	await d.choose("A fair offer.")
	var log: PackedStringArray = d.log_lines()
	var i_align: int = log.find("You performed an action that was (Lawful).")
	var i_one: int = log.find("The demon's mood seems to improve.")
	var i_three: int = log.find("The demon's mood brightens considerably.")
	var i_line: int = log.find("Ada\nDeal, then.")
	check("the order is alignment, then each effect in turn, then the spoken line",
		i_align >= 0 and i_align < i_one and i_one < i_three and i_three < i_line, str(log))
	check("the alignment lands on the actor", ada.alignment == start_alignment + 10)
	check("the flag is set", FlagManager.has_flag(flag))
	check("the effects add up in the mood", d.mood() == 4, str(d.mood()))
	# Changed by the rewrite: a negotiation keeps a transcript like any
	# conversation, so the spoken line is its newest entry.
	check("it goes into the negotiation's own transcript, the spoken line last",
		d.transcript().size() > said and d.last_said() == "Deal, then.", str(d.transcript_texts()))
	check("and neither the demon's words nor the choice text are logged",
		not d.log_has("The demon eyes you.") and not d.log_has("A fair offer."), str(log))
	check("though the demon's words are in the transcript, narrated like any node's",
		d.transcript_texts().has("The demon eyes you."), str(d.transcript_texts()))
	d.end_negotiation("attack")
	ada.alignment = start_alignment
	await _tidy(imp)


## shift_mood_notes, neg_mood_notes.
## Shifted on a live negotiation: mood is a variable of the conversation
## that holds it, so there is nothing to shift once none is running.
func _mood_notes() -> void:
	var root: DialogueNode = d.node("n_root", "Hm?", [d.neg_outcome("Bye.", "attack")])
	d.register_negotiation([root])
	var imp: Unit = await _demon_on(root)
	d.start_negotiation(ada, imp)
	d.clear_events()
	d.set_mood(0)
	d.shift_mood(3)
	d.shift_mood(1)
	d.shift_mood(-3)
	d.shift_mood(-1)
	d.shift_mood(0)
	check("each non-zero shift is announced by size and sign, and 0 is silent", str(d.events) == str([
		"mood_note:The demon's mood brightens considerably.",
		"mood_note:The demon's mood seems to improve.",
		"mood_note:That visibly sours the demon's mood.",
		"mood_note:The mood turns a bit awkward..."]), str(d.events))
	check("and each is logged too", d.log_count("The mood turns a bit awkward...") == 1)
	check("the shifts add up", d.mood() == 0)
	d.shift_mood(2)
	d.shift_mood(-2)
	check("2 improves, -2 is awkward", str(d.events.slice(-2)) == str([
		"mood_note:The demon's mood seems to improve.", "mood_note:The mood turns a bit awkward..."]),
		str(d.events))
	d.end_negotiation("attack")
	await _tidy(imp)


## volatile_mood_effect, neg_volatile_mood.
func _volatile() -> void:
	var root: DialogueNode = d.node("v_root", "Hmph.", [
		d.neg_line("Poke.", "v_root", {"repeatable": true, "effects": [d.volatile_mood_effect(-2, 3)]}),
		d.neg_outcome("Bye.", "attack")])
	d.register_negotiation([root])
	var imp: Unit = await _demon_on(root)
	d.start_negotiation(ada, imp)
	d.set_mood(0)
	d.clear_events()
	d.pin_volatile(-2, 3, 3)
	await d.choose("Poke.")
	check("a volatile shift rolls within its range: 3 brightens considerably",
		d.mood() == 3 and d.event_count("mood_note:The demon's mood brightens considerably.") == 1, str(d.events))
	d.clear_events()
	d.pin_volatile(-2, 3, 0)
	await d.choose("Poke.")
	check("a roll of 0 changes nothing and says nothing", d.mood() == 3 and d.event_count("mood_note") == 0)
	d.pin_volatile(-2, 3, -2)
	await d.choose("Poke.")
	check("and it can go down", d.mood() == 1 and d.event_count("mood_note:The mood turns a bit awkward...") == 1)
	d.end_negotiation("attack")
	await _tidy(imp)


## disliked_pardon_once, disliked_no_mood_change, neg_pardon_once.
func _one_pardon() -> void:
	var root: DialogueNode = d.node("p_root", "Careful.", [
		d.disliked("Rude.", "p_root"), d.disliked("Ruder.", "p_root"), d.neg_outcome("Bye.", "attack")])
	d.register_negotiation([root])
	var imp: Unit = await _demon_on(root)
	d.start_negotiation(ada, imp)
	var mood_then: int = d.mood()
	d.clear_events()
	await d.choose("Rude.")
	check("the first disliked answer is let slide, and the tree goes on",
		d.negotiation_active() and d.current_node_id() == "p_root" and d.log_has("The demon lets that one slide... this time."),
		str(d.log_lines()))
	check("the pardon is spent", not d.pardon_available())
	check("a disliked answer moves no mood and makes no mood note",
		d.mood() == mood_then and d.event_count("mood_note") == 0, str(d.events))
	await d.choose("Ruder.")
	check("the second one ends it as FLEE", not d.negotiation_active() and d.events.back() == "negotiation_ended:FLEE",
		str(d.events))
	check("with the flee line and no second pardon line",
		d.log_count("breaks off and flees.") == 1 and d.log_count("lets that one slide") == 1, str(d.log_lines()))
	await get_tree().process_frame
	check("and the demon is gone", _gone(imp))
	await _tidy(imp)


## hated_attack, neg_hated_attack.
func _hated_is_a_fight() -> void:
	var root: DialogueNode = d.node("h_root", "Say it.", [d.hated("Your mother.")])
	d.register_negotiation([root])
	var imp: Unit = await _demon_on(root)
	d.start_negotiation(ada, imp)
	d.clear_events()
	await d.choose("Your mother.")
	check("a hated answer ends it as ATTACK", d.events.back() == "negotiation_ended:ATTACK", str(d.events))
	check("the pardon is not spent on it", d.pardon_available())
	check("and the demon stays, hostile, in the fight", imp.is_alive() and imp.in_combat() and imp.is_hostile_to(ada))
	check("logged as a trick", d.log_has("was a trick"), str(d.log_lines()))
	await _tidy(imp)


## neg_empty_choices_flee, empty_choices_flee, neg_empty_or_unknown_next_flee,
## empty_next_id_flee, unknown_next_id_flee, node_index_separate_namespace,
## outcome_choice_ends (the unset-outcome half).
func _dead_ends_flee() -> void:
	FlagManager.clear_flag("conv_neg_never")
	var never: PrerequisiteRule = d.needs_flag("conv_neg_never")
	var walled: DialogueNode = d.node("e_walled", "Nothing to say.", [d.neg_line("Hidden.", "e_walled", {"requires": never})])
	var root: DialogueNode = d.node("e_root", "Go on.", [
		d.neg_line("To the wall.", "e_walled"), d.neg_line("Nowhere.", ""), d.neg_line("Lost.", "e_no_such_node"),
		d.neg_line("To dialogue.", "e_dialogue_only"), d.neg_outcome("Unset.", "continue")])
	d.register_negotiation([walled, root])
	d.register_dialogue([d.node("e_dialogue_only", "Only dialogue knows me.")])

	# Every one of these dead ends is also caught before play, by the
	# authoring pass a negotiation folder is linted under. It names no kind
	# of effect: the ending effect says it ends the tree, the unset outcome
	# says what is wrong with it.
	var found: PackedStringArray = []
	for problem in d.authoring_problems(true, true):
		if problem.contains("'e_root'"):
			found.append(problem)
	check("lint: the empty next id outside an ending is flagged, once",
		Array(found).filter(func(p): return p.contains("is empty")).size() == 1, str(found))
	check("lint: the unset outcome reports itself",
		Array(found).any(func(p): return p.contains("outcome is left unset")), str(found))
	check("lint: both unknown ids are flagged, the dialogue-only one included",
		Array(found).any(func(p): return p.contains("'e_no_such_node'"))
		and Array(found).any(func(p): return p.contains("'e_dialogue_only'")), str(found))
	var lenient: PackedStringArray = d.authoring_problems(true, false)
	check("lint: outside strict, an empty next id is the normal way to finish",
		not Array(lenient).any(func(p): return p.contains("'e_root'") and p.contains("is empty")), str(lenient))

	var imp: Unit = await _demon_on(walled)
	d.clear_events()
	d.start_negotiation(ada, imp)
	# Changed by the rewrite: the dead end is taken before the node is
	# shown, so its line is never put up only to be torn down at once. The
	# engine does this for every node, not just the root: "To the wall."
	# below walks into the same node mid-tree and is pinned the same way.
	check("a root with nothing to choose ends at once as FLEE, with no line and no choices",
		str(d.events) == str(["negotiation_started:%s" % imp.get_display_name(),
			"negotiation_ended:FLEE"]), str(d.events))
	await get_tree().process_frame
	check("and the demon leaves", _gone(imp))
	await _tidy(imp)

	check("setup: the id is dialogue's, not negotiation's",
		d.dialogue_knows("e_dialogue_only") and not d.negotiation_knows("e_dialogue_only"))
	for pick in ["To the wall.", "Nowhere.", "Lost.", "To dialogue.", "Unset."]:
		imp = await _demon_on(root)
		d.start_negotiation(ada, imp)
		d.clear_events()
		await d.choose(pick)
		check("'%s' ends as FLEE" % pick, not d.negotiation_active() and d.events.has("negotiation_ended:FLEE"),
			str(d.events))
		if pick == "To the wall.":
			check("a dead end reached mid-tree flees before its line is shown, too",
				d.event_count("neg_line:Nothing to say.") == 0 and d.event_count("neg_choices") == 0,
				str(d.events))
		await get_tree().process_frame
		check("'%s' sends the demon away" % pick, _gone(imp))
		await _tidy(imp)


## lethal_effect_ends_flee, neg_lethal_cost_ends.
func _a_lethal_price_ends_it() -> void:
	var cato: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(-1, 0, -2))
	cato.display_name = "Cato"
	fight.add_unit(cato)
	var root: DialogueNode = d.node("l_root", "Blood.", [
		d.neg_line("Take it all.", "l_root", {"spoken": "Ugh.", "effects": [d.hp_cost(9999), d.mood_effect(3)]})])
	d.register_negotiation([root])
	var imp: Unit = await _demon_on(root)
	d.start_negotiation(cato, imp)
	var mood_then: int = d.mood()
	d.clear_events()
	await d.choose("Take it all.")
	check("a price that kills the actor ends it as FLEE", not cato.is_alive() and d.events.has("negotiation_ended:FLEE"),
		str(d.events))
	check("the effects after it do not run", d.mood() == mood_then and d.event_count("mood_note") == 0)
	check("and the spoken line is not logged", not d.log_has("Ugh."))
	await get_tree().process_frame
	check("the demon leaves too", _gone(imp))
	await _tidy(imp)
	if is_instance_valid(cato):
		remove_spawned(cato)
	await get_tree().process_frame
