extends AiTestCase
## Pins how a dialogue moves once it is open: which choices a node shows,
## what picking one records and in what order, where it goes next, and
## the three ways it can end. These are the rules every authored tree in
## data/dialogue leans on without saying so (a hub loop only works
## because used choices hide and the hub is not narrated twice), so a
## rewrite that drifts on one of them breaks content without a script
## error anywhere.
##
## Some pins here are awkward on purpose: a lethal cost does not stop a
## dialogue. That is today's behaviour, pinned until someone decides. The
## rewrite knowingly changed two: a node whose choices are all filtered
## out no longer leaves the player stuck, and a choice that ends the
## conversation no longer loads its next node afterwards.
##
## Bare battlefield, no world: nothing here reads WorldManager.
## Everything goes through conversation_driver.gd. See its header.

const Driver := preload("res://tests/conversation/conversation_driver.gd")

var d: Driver
var ada: Unit
var npc: Unit


func run() -> void:
	d = Driver.new()
	add_child(d)
	d.begin()
	ada = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3.ZERO)
	ada.display_name = "Ada"
	npc = spawn_unit(&"neutral", 10, 10, 10, [melee()], Vector3(2, 0, 0))
	npc.display_name = "Brom"

	await _hub_loop()
	await _prerequisites()
	await _choose_guards()
	await _resolution_order()
	await _routing_and_endings()
	await _interjections()
	await _advance()
	await _all_filtered_softlock()
	await _costs()

	d.finish()


func _pair() -> Dictionary:
	return {"player": ada, "npc": npc}


## dlg_node_narrated_once, dlg_used_choice_hidden,
## dlg_used_choice_key_full_index, dlg_row_index_maps_visible_list.
func _hub_loop() -> void:
	var hub: DialogueNode = d.node("w_hub", "What do you want?", [
		d.line("Ask about the road.", "w_road"),
		d.line("Ask about the weather.", "w_hub", {"repeatable": true}),
		d.line("Goodbye.")])
	var road: DialogueNode = d.node("w_road", "It is long.", [d.line("Back.", "w_hub")])
	d.register_dialogue([hub, road])
	d.clear_events()
	d.start_dialogue(hub, _pair())

	await d.choose("Ask about the road.")
	await d.choose("Back.")
	check("back at the hub", d.current_node_id() == "w_hub")
	check("a picked choice is hidden on the next visit",
		d.choices() == PackedStringArray(["Ask about the weather.", "Goodbye."]), str(d.choices()))
	check("the hub is narrated once, not again on the return",
		d.transcript_texts().count("What do you want?") == 1, str(d.transcript_texts()))
	check("but its choices are shown again",
		d.event_count("choices:") == 3, str(d.events))

	await d.choose("Ask about the weather.")
	check("a repeatable choice stays after being picked",
		d.choices().has("Ask about the weather."), str(d.choices()))
	check("used choices are keyed by the choice's place in the node",
		d.was_used("w_hub", 0) and d.was_used("w_hub", 1) and not d.was_used("w_hub", 2))

	# Row 0 is now "Ask about the weather." because authored choice 0 is
	# hidden: a row indexes what is shown, never what is authored.
	d.clear_events()
	await d.choose_row(1)
	check("row 1 picks the second VISIBLE choice (Goodbye), which ends it",
		not d.dialogue_active() and d.events.has("dialogue_ended"), str(d.events))
	check("and records it under its authored place", d.was_used("w_hub", 2))


## dlg_prereq_filter_player.
func _prerequisites() -> void:
	var gate: String = "conv_test_gate"
	FlagManager.clear_flag(gate)
	var hub: DialogueNode = d.node("w_gate", "Anything else?", [
		d.line("Open the gate.", "w_gate", {"requires": d.needs_flag(gate)}),
		d.line("Set the gate flag.", "w_gate", {"flag": gate}),
		d.line("Only without it.", "w_gate", {"requires": d.needs_flag(gate, true), "repeatable": true}),
		d.line("Goodbye.")])
	d.register_dialogue([hub])
	d.start_dialogue(hub, _pair())
	check("a choice whose requirement fails is hidden",
		d.choices() == PackedStringArray(["Set the gate flag.", "Only without it.", "Goodbye."]),
		str(d.choices()))
	await d.choose("Set the gate flag.")
	check("picking a choice sets its flag", FlagManager.has_flag(gate))
	check("requirements are asked again on every show",
		d.choices() == PackedStringArray(["Open the gate.", "Goodbye."]), str(d.choices()))
	d.end_dialogue()
	FlagManager.clear_flag(gate)


## dlg_choose_guards.
func _choose_guards() -> void:
	d.clear_events()
	await d.choose_row_in(false, 0)
	check("choosing with nothing open does nothing", d.events.is_empty(), str(d.events))

	d.start_dialogue(d.node("w_guard", "Pick.", [d.line("Only one.")]), _pair())
	d.clear_events()
	await d.choose_row(-1)
	await d.choose_row(1)
	check("an out-of-range row does nothing",
		d.events.is_empty() and d.dialogue_active() and d.used_count() == 0, str(d.events))
	d.end_dialogue()


## dlg_resolve_order, dlg_flag_set, dlg_choose_no_active_check_after_resolve.
func _resolution_order() -> void:
	var flag: String = "conv_test_order"
	FlagManager.clear_flag(flag)
	var seen: Array = []
	var start_alignment: int = ada.alignment
	var root: DialogueNode = d.node("w_order", "Choose.", [
		d.line("Do it all.", "w_after", {"alignment": "Lawful", "flag": flag, "spoken": "So be it.",
			"effects": [d.marker_effect(seen, "first"), d.marker_effect(seen, "second")]})])
	var after: DialogueNode = d.node("w_after", "Done.", [d.line("Bye.")])
	d.register_dialogue([root, after])
	d.start_dialogue(root, _pair())
	await d.choose("Do it all.")

	var said: Array[Dictionary] = d.transcript()
	check("the alignment is applied to the actor", ada.alignment == start_alignment + 10)
	check("the alignment is announced first, as an unspoken line",
		said[1].speaker == "" and said[1].text == "You performed an action that was (Lawful).", str(said[1]))
	check("the flag is set", FlagManager.has_flag(flag))
	check("effects run in order, after the alignment line and before the spoken line",
		seen == ["first@2", "second@2"], str(seen))
	check("the spoken line comes after the effects, in the player's voice",
		said[2].speaker == "Ada" and said[2].text == "So be it.", str(said[2]))
	check("then it routes", d.current_node_id() == "w_after")
	d.end_dialogue()
	FlagManager.clear_flag(flag)

	var ends: DialogueNode = d.node("w_ends", "Hm.", [d.line("End it, then go on.", "w_after",
		{"effects": [d.ending_effect()]})])
	d.register_dialogue([ends])
	d.start_dialogue(ends, _pair())
	d.clear_events()
	await d.choose("End it, then go on.")
	# Changed by the rewrite: the old manager ended, then loaded the next
	# node into a conversation it had just closed. An ending now stands.
	check("a choice that ends the dialogue while resolving stays ended",
		d.event_count("dialogue_ended") == 1 and not d.dialogue_active() and d.current_node_id() == "",
		str(d.events))


## dlg_line_choice_routing, dlg_empty_next_ends, dlg_unknown_next_ends_with_error.
func _routing_and_endings() -> void:
	var home: DialogueNode = d.node("w_home", "Home again.", [d.line("Bye.")])
	var away: DialogueNode = d.node("w_away", "Far off.", [
		d.line("Go home.", "", {"to_root": true}), d.line("Nowhere.", "w_no_such_node")])
	d.register_dialogue([home, away])
	d.give_dialogue(npc, home)
	d.start_dialogue(away, _pair())
	await d.choose("Go home.")
	check("back-to-root goes to the root the NPC would open on now",
		d.current_node_id() == "w_home", d.current_node_id())
	d.end_dialogue()

	d.silence(npc)
	d.start_dialogue(away, _pair())
	d.clear_events()
	await d.choose("Go home.")
	check("back-to-root with no root to go to ends the conversation",
		not d.dialogue_active() and d.events.has("dialogue_ended"), str(d.events))

	d.start_dialogue(away, _pair())
	d.clear_events()
	await d.choose("Nowhere.")
	check("an id that names no node ends the conversation (and errors)",
		not d.dialogue_active() and d.events.has("dialogue_ended"), str(d.events))

	d.start_dialogue(home, _pair())
	d.clear_events()
	await d.choose("Bye.")
	check("an empty next id ends the conversation",
		not d.dialogue_active() and d.events == ["dialogue_ended"], str(d.events))


## dlg_interjection_preempts_once.
func _interjections() -> void:
	var flag: String = "conv_test_interject"
	FlagManager.clear_flag(flag)
	var hub: DialogueNode = d.node("w_ihub", "Hub.", [
		d.line("To the yard.", "w_yard"), d.line("To the yard again.", "w_yard"), d.line("Bye.")])
	var yard: DialogueNode = d.node("w_yard", "The yard.", [d.line("Back.", "w_ihub", {"repeatable": true})])
	var gated: DialogueNode = d.node("w_gated", "Never, the flag is off.", [d.line("Back.", "w_ihub")])
	var cut_in: DialogueNode = d.node("w_shout", "Someone shouts!", [d.line("Back.", "w_ihub")])
	d.interject(yard, gated, d.needs_flag(flag))
	d.interject(yard, cut_in)
	d.register_dialogue([hub, yard, gated, cut_in])
	d.start_dialogue(hub, _pair())
	await d.choose("To the yard.")
	check("the first interjection whose requirement holds is shown instead",
		d.current_node_id() == "w_shout", d.current_node_id())
	await d.choose("Back.")
	await d.choose("To the yard again.")
	check("each interjection fires once per conversation",
		d.current_node_id() == "w_yard", d.current_node_id())
	d.end_dialogue()


## dlg_advance_semantics.
func _advance() -> void:
	var first: DialogueNode = d.node("w_lin1", "One.", [], "npc", "w_lin2")
	var second: DialogueNode = d.node("w_lin2", "Two.", [])
	d.register_dialogue([first, second])
	d.start_dialogue(first, _pair())
	check("a node with no choices shows no choices", d.choices().is_empty())
	d.advance()
	check("advance follows the next id", d.current_node_id() == "w_lin2")
	d.clear_events()
	d.advance()
	check("advance on the last node ends it",
		not d.dialogue_active() and d.events == ["dialogue_ended"], str(d.events))

	d.start_dialogue(d.node("w_has", "Pick one.", [d.line("This.")], "npc", "w_lin2"), _pair())
	d.advance()
	check("advance on a node that has choices does nothing",
		d.dialogue_active() and d.current_node_id() == "w_has")
	d.end_dialogue()


## dlg_all_choices_filtered_softlock.
func _all_filtered_softlock() -> void:
	var never: String = "conv_test_never"
	FlagManager.clear_flag(never)
	d.start_dialogue(d.node("w_stuck", "Stuck.", [
		d.line("Hidden.", "", {"requires": d.needs_flag(never)})]), _pair())
	check("every choice filtered: an empty choice list is shown",
		d.choices().is_empty() and d.events.back() == "choices:0", str(d.events))
	# Changed by the rewrite: Continue reads the choices the player can
	# see, not the ones authored, so a node filtered down to nothing
	# offers the same way out as a node with none, and the old softlock
	# is gone.
	d.advance()
	check("and advance leaves as it would from a node with no choices",
		not d.dialogue_active() and d.events.back() == "dialogue_ended", str(d.events))


## dlg_gold_effect_insufficient, dlg_no_lethal_check, dlg_give_sacrifice_item (FP part).
func _costs() -> void:
	CurrencyManager.gold = 5
	var root: DialogueNode = d.node("w_cost", "Pay.", [
		d.line("Pay 50.", "w_paid", {"effects": [d.gold_cost(50)]}),
		d.line("Pay 3.", "w_paid", {"effects": [d.gold_cost(3)]}),
		d.line("Spend FP.", "w_paid", {"effects": [d.fp_cost(4)]}),
		d.line("Bleed out.", "w_paid", {"effects": [d.hp_cost(99), d.fp_cost(1)]})])
	var paid: DialogueNode = d.node("w_paid", "Paid.", [d.line("Again.", "w_cost", {"repeatable": true})])
	d.register_dialogue([root, paid])
	d.start_dialogue(root, _pair())

	await d.choose("Pay 50.")
	check("gold it cannot afford is not spent", CurrencyManager.gold == 5)
	check("and the choice goes ahead anyway", d.current_node_id() == "w_paid")
	await d.choose("Again.")
	await d.choose("Pay 3.")
	check("gold it can afford is spent", CurrencyManager.gold == 2)

	ada.fp_bonus = 10 - ada.health
	ada.current_fp = 3
	await d.choose("Again.")
	d.clear_events()
	await d.choose("Spend FP.")
	check("an FP cost never takes FP below zero", ada.current_fp == 0, str(ada.current_fp))
	check("and is logged", d.log_has("Ada spends 4 FP."), str(d.log_lines()))

	await d.choose("Again.")
	ada.current_fp = 5
	await d.choose("Bleed out.")
	check("a lethal cost kills the actor", ada.current_hp <= 0)
	check("but dialogue has no lethal stop: later effects still apply", ada.current_fp == 4)
	check("and it still routes on", d.dialogue_active() and d.current_node_id() == "w_paid")
	d.end_dialogue()
