extends AiTestCase
## Pins what the player SEES of a negotiation today: negotiation_panel.tscn,
## the separate, lighter screen that is not the dialogue band. The
## rewrite plans to fold negotiation into the one conversation screen, so
## this is the record of what that screen has to reproduce: the header,
## the {gold}-formatted line, the mood note that rides on the NEXT line
## only, the mood swatch that changes only when a note arrives (not at
## start, whatever the starting mood), the numbered [url] choice list,
## the click that picks the VISIBLE row, and the close on any ending.
##
## Every assertion is on what is rendered (is_visible_in_tree, label
## text), because a manager that is right behind an invisible panel has
## shipped green here before. The panel is the real scene, instanced
## bare; the UIStack flags are read from MainRoot.tscn as authored.
##
## wants_world(): a negotiation only starts inside a fight. Everything
## goes through conversation_driver.gd.

const Driver := preload("res://tests/conversation/conversation_driver.gd")

var d: Driver
var ada: Unit
var goblin: Unit
var fight: Encounter
var panel: UIScreen


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
	panel = d.make_panel(_root)
	await get_tree().process_frame

	_authored_flags()
	await _opens_on_start()
	await _mood_notes()
	await _choices_and_clicks()
	await _closes_on_every_ending()

	UIStack.close_all()
	panel.queue_free()
	d.finish()


func _demon_on(root: DialogueNode) -> Unit:
	var imp: Unit = d.spawn_species(self, d.species_with_roots("goblin_rogue", [[root, null]]), Vector3(-2, 0, 2))
	imp.display_name = "Imp"
	fight.add_unit(imp)
	await get_tree().process_frame
	return imp


func _tidy(unit: Unit) -> void:
	if is_instance_valid(unit):
		remove_spawned(unit)
	await get_tree().process_frame


## panel_hidden_at_boot, panel UIStack flags.
func _authored_flags() -> void:
	var flags: Dictionary = d.authored_screen_flags("NegotiationPanel")
	check("MainRoot has the negotiation panel", flags.found)
	check("it hides the HUD", flags.hides_hud)
	check("it blocks input below it", flags.blocks_input_below)
	check("it does NOT keep the party rail up (the dialogue band does)", not flags.keeps_party_visible)
	check("Escape does not close it", not flags.closes_on_cancel)
	check("it starts hidden", not d.panel_view(panel).visible)


## panel_opens_on_start, panel_line_render, panel_mood_indicator_color (start).
func _opens_on_start() -> void:
	var root: DialogueNode = d.node("pn_open", "Pay me {gold}.", [d.neg_outcome("Leave.", "attack")])
	d.register_negotiation([root])
	var imp: Unit = await _demon_on(root)
	ada.alignment = 30
	ada.tendency = -30
	imp.alignment = 0
	imp.tendency = 0
	d.start_negotiation(ada, imp)
	ada.alignment = 0
	ada.tendency = 0
	await get_tree().process_frame
	var view: Dictionary = d.panel_view(panel)
	check("starting a negotiation shows the panel", view.visible)
	check("headed with the demon's name", view.header == "Imp is willing to talk.", view.header)
	check("the line is shown with {gold} filled in",
		view.line == "Pay me %d." % d.negotiated_gold(), view.line)
	check("the swatch starts neutral even though the opening mood is %d" % d.mood(),
		d.mood() != 0 and view.mood_color == Driver.MOOD_NEUTRAL, str(view.mood_color))
	d.end_negotiation("attack")
	await get_tree().process_frame
	await _tidy(imp)


## panel_mood_note_latest_only, panel_mood_indicator_color.
func _mood_notes() -> void:
	var root: DialogueNode = d.node("pn_mood", "Well?", [
		d.neg_line("Flatter.", "pn_mood", {"repeatable": true, "effects": [d.mood_effect(3)]}),
		d.neg_line("Insult.", "pn_mood", {"repeatable": true, "effects": [d.mood_effect(-1)]}),
		d.neg_line("Both.", "pn_mood", {"effects": [d.mood_effect(1), d.mood_effect(-3)]}),
		d.neg_line("Nothing.", "pn_mood", {"repeatable": true}),
		d.neg_outcome("Leave.", "attack")])
	d.register_negotiation([root])
	var imp: Unit = await _demon_on(root)
	d.start_negotiation(ada, imp)
	d.set_mood(0)
	await d.choose("Flatter.")
	await get_tree().process_frame
	var view: Dictionary = d.panel_view(panel)
	check("a mood shift rides under the next line as a grey italic note",
		view.line == "Well?\n\n[i][color=#999999]The demon's mood brightens considerably.[/color][/i]", view.line)
	check("and turns the swatch positive", view.mood_color == Driver.MOOD_POSITIVE, str(view.mood_color))

	await d.choose("Nothing.")
	await get_tree().process_frame
	view = d.panel_view(panel)
	check("the note is shown once: the line after it is bare", view.line == "Well?", view.line)
	check("and the swatch keeps its colour when no note comes", view.mood_color == Driver.MOOD_POSITIVE)

	await d.choose("Both.")
	await get_tree().process_frame
	view = d.panel_view(panel)
	check("two shifts on one choice show only the later note",
		view.line.contains("That visibly sours the demon's mood.") and not view.line.contains("seems to improve"), view.line)
	check("the swatch follows the running mood, not the last shift (3 + 1 - 3 = 1 is positive)",
		d.mood() == 1 and view.mood_color == Driver.MOOD_POSITIVE, "%d %s" % [d.mood(), view.mood_color])

	await d.choose("Insult.")
	await get_tree().process_frame
	view = d.panel_view(panel)
	check("a running mood of zero is neutral", d.mood() == 0 and view.mood_color == Driver.MOOD_NEUTRAL)
	await d.choose("Insult.")
	await get_tree().process_frame
	check("below zero is negative", d.panel_view(panel).mood_color == Driver.MOOD_NEGATIVE)
	d.end_negotiation("attack")
	await get_tree().process_frame
	await _tidy(imp)


## panel_choice_list, panel_click_chooses.
func _choices_and_clicks() -> void:
	var root: DialogueNode = d.node("pn_rows", "Choose.", [
		d.neg_line("First.", "pn_rows"),
		d.neg_line("Costs {gold}.", "pn_rows"),
		d.neg_line("Third.", "pn_rows")])
	d.register_negotiation([root])
	var imp: Unit = await _demon_on(root)
	d.start_negotiation(ada, imp)
	await get_tree().process_frame
	var gold: int = d.negotiated_gold()
	check("choices render as numbered [url] links, one per line, {gold} filled in",
		d.panel_view(panel).choices == "[url=0]1. First.[/url]\n[url=1]2. Costs %d.[/url]\n[url=2]3. Third.[/url]" % gold,
		d.panel_view(panel).choices)
	d.panel_click(panel, 0)
	await get_tree().process_frame
	await get_tree().process_frame
	check("clicking a link picks that choice; the list renumbers without it",
		d.was_used("pn_rows", 0, true)
		and d.panel_view(panel).choices == "[url=0]1. Costs %d.[/url]\n[url=1]2. Third.[/url]" % gold,
		d.panel_view(panel).choices)
	d.panel_click(panel, 1)
	await get_tree().process_frame
	await get_tree().process_frame
	check("the link index is the VISIBLE row: row 1 is now Third",
		d.was_used("pn_rows", 2, true) and not d.was_used("pn_rows", 1, true))
	d.end_negotiation("attack")
	await get_tree().process_frame
	await _tidy(imp)


## panel_closes_on_end.
func _closes_on_every_ending() -> void:
	for ending in ["attack", "flee"]:
		var root: DialogueNode = d.node("pn_end_" + ending, "Bye?", [d.neg_outcome("Go.", ending)])
		d.register_negotiation([root])
		var imp: Unit = await _demon_on(root)
		d.start_negotiation(ada, imp)
		await get_tree().process_frame
		check("setup: the panel is up for " + ending, d.panel_view(panel).visible)
		d.panel_click(panel, 0)
		await get_tree().process_frame
		await get_tree().process_frame
		check("a %s ending closes the panel" % ending, not d.negotiation_active() and not d.panel_view(panel).visible)
		await _tidy(imp)
