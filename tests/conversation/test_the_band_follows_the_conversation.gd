extends AiTestCase
## Pins what the player SEES of a dialogue today: the lower-third band
## (dialogue_overlay.tscn), the conversation log it toggles, and the dice
## popup a check waits on. The rewrite will replace the signals these
## screens listen to, so these are the pins that say whether it kept the
## screens working, not just the manager. Every assertion is about what
## is rendered (is_visible_in_tree, label text), because a manager that
## is right behind an invisible panel has shipped green here before.
##
## Real scenes, instanced bare under the suite's root: no MainRoot, so
## the UIStack flags MainRoot authors are read from MainRoot.tscn itself
## (authored_screen_flags) rather than observed through a live HUD. The
## per-row tag rendering and the log's own contents are pinned by
## tests/dialogue; this suite checks the band only as far as the
## conversation drives it.
##
## Everything goes through conversation_driver.gd.

const Driver := preload("res://tests/conversation/conversation_driver.gd")

var d: Driver
var ada: Unit
var npc: Unit
var overlay: UIScreen
var log_screen: UIScreen
var dice: Control


func run() -> void:
	d = Driver.new()
	add_child(d)
	d.begin()
	ada = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3.ZERO)
	ada.display_name = "Ada"
	ada.selected_color = Color(0.2, 0.4, 0.9)
	npc = spawn_unit(&"neutral", 10, 10, 10, [melee()], Vector3(2, 0, 0))
	npc.display_name = "Brom"
	overlay = d.make_overlay(_root)
	log_screen = d.make_log(_root)
	await get_tree().process_frame

	_authored_flags()
	await _opens_and_speaks()
	await _rows_and_clicks()
	await _continue_and_end()
	await _softlock_is_visible()
	await _log_chip()
	await _dice_popup_flow()
	await _dice_popup_follows_and_lets_go()

	UIStack.close_all()
	d.finish()


func _pair() -> Dictionary:
	return {"player": ada, "npc": npc}


## overlay_uistack_flags.
func _authored_flags() -> void:
	var flags: Dictionary = d.authored_screen_flags("DialogueOverlay")
	check("MainRoot has the dialogue band", flags.found)
	check("the band hides the HUD", flags.hides_hud)
	check("the band blocks input below it", flags.blocks_input_below)
	check("the band keeps the party rail up", flags.keeps_party_visible)
	check("Escape does not close the band", not flags.closes_on_cancel)
	check("the band starts hidden", not d.overlay_view(overlay).visible)


## overlay_open_on_start, overlay_line_display.
func _opens_and_speaks() -> void:
	var root: DialogueNode = d.node("b_open", "Evening.", [
		d.line("Nod.", "b_open2", {"alignment": "Lawful"})])
	var second: DialogueNode = d.node("b_open2", "Quiet night.", [d.line("Bye.")])
	d.register_dialogue([root, second])
	d.start_dialogue(root, _pair())
	await get_tree().process_frame
	var view: Dictionary = d.overlay_view(overlay)
	check("starting a dialogue shows the band", view.visible)
	check("the speaker is shown upper-cased", view.speaker == "BROM", view.speaker)
	check("in the player's colour", view.speaker_color == ada.selected_color, str(view.speaker_color))
	check("with the line", view.line == "Evening.", view.line)
	check("the aside starts empty", view.aside == "", view.aside)

	await d.choose("Nod.")
	await get_tree().process_frame
	view = d.overlay_view(overlay)
	check("an unspoken line goes to the aside only",
		d.plain(view.aside) == "You performed an action that was (Lawful)." , view.aside)
	check("and a spoken line after it still replaces speaker and line",
		view.speaker == "BROM" and view.line == "Quiet night.", view.line)
	d.end_dialogue()
	await get_tree().process_frame

	d.start_dialogue(d.node("b_again", "Back so soon?", [d.line("Bye.")]), _pair())
	await get_tree().process_frame
	check("a new dialogue clears the old aside", d.overlay_view(overlay).aside == "")
	d.end_dialogue()


## overlay_choice_rows (numbering, focus, click -> visible row).
func _rows_and_clicks() -> void:
	var hub: DialogueNode = d.node("b_hub", "Well?", [
		d.line("First.", "b_hub"), d.line("Second.", "b_hub"), d.line("Third.")])
	d.register_dialogue([hub])
	d.start_dialogue(hub, _pair())
	await get_tree().process_frame
	var rows: Array = d.overlay_view(overlay).rows
	check("one row per visible choice, numbered 01, 02, 03",
		rows.size() == 3 and rows[0].index == "01" and rows[2].index == "03" and rows[1].text == "Second.",
		str(rows))
	check("every row is on screen", rows.all(func(r): return r.visible))
	check("the first row has focus", rows[0].focused)

	d.overlay_click_row(overlay, 0)
	await get_tree().process_frame
	await get_tree().process_frame
	rows = d.overlay_view(overlay).rows
	check("clicking a row picks that choice; it is gone on the return",
		rows.size() == 2 and rows[0].text == "Second." and rows[0].index == "01", str(rows))
	d.overlay_click_row(overlay, 1)
	await get_tree().process_frame
	check("clicking the second VISIBLE row picks Third, which ends it",
		not d.dialogue_active() and not d.overlay_view(overlay).visible)


## overlay_continue_button, overlay_close_on_end.
func _continue_and_end() -> void:
	var a: DialogueNode = d.node("b_lin1", "One.", [], "npc", "b_lin2")
	var b: DialogueNode = d.node("b_lin2", "Two.", [])
	d.register_dialogue([a, b])
	d.start_dialogue(a, _pair())
	await get_tree().process_frame
	var view: Dictionary = d.overlay_view(overlay)
	check("a node with no choices shows Continue instead of rows",
		view.continue_visible and view.rows.is_empty() and view.continue_text == "Continue", str(view))
	check("enabled and focused", not view.continue_disabled and view.continue_focused)
	d.overlay_press_continue(overlay)
	await get_tree().process_frame
	view = d.overlay_view(overlay)
	check("Continue advances", d.current_node_id() == "b_lin2" and view.line == "Two.")
	check("on the last node it reads End Conversation", view.continue_text == "End Conversation", view.continue_text)
	d.overlay_press_continue(overlay)
	await get_tree().process_frame
	check("and pressing it ends the dialogue and hides the band",
		not d.dialogue_active() and not d.overlay_view(overlay).visible)


## dlg_all_choices_filtered_softlock (as the player sees it), which the
## rewrite removed: a filtered-out node is left like any last node.
func _softlock_is_visible() -> void:
	FlagManager.clear_flag("conv_band_never")
	d.start_dialogue(d.node("b_stuck", "Stuck.", [
		d.line("Hidden.", "", {"requires": d.needs_flag("conv_band_never")})]), _pair())
	await get_tree().process_frame
	var view: Dictionary = d.overlay_view(overlay)
	check("all choices filtered: the band shows End Conversation",
		view.continue_visible and view.continue_text == "End Conversation", str(view))
	d.overlay_press_continue(overlay)
	await get_tree().process_frame
	# Changed by the rewrite: the button said End Conversation and did
	# nothing. It now does what it says, as on any last node.
	check("and pressing it ends the dialogue and hides the band",
		not d.dialogue_active() and not d.overlay_view(overlay).visible)


## overlay_chips, overlay_close_on_end (log half).
func _log_chip() -> void:
	d.start_dialogue(d.node("b_log", "Read back.", [d.line("Bye.")]), _pair())
	await get_tree().process_frame
	check("the log starts closed", not log_screen.is_visible_in_tree())
	d.overlay_press_log(overlay)
	check("the log chip opens the log", log_screen.is_visible_in_tree())
	d.overlay_press_log(overlay)
	check("and closes it again", not log_screen.is_visible_in_tree())
	d.overlay_press_log(overlay)
	d.end_dialogue()
	await get_tree().process_frame
	check("ending the dialogue closes an open log too", not log_screen.is_visible_in_tree())


## dice_popup_flow, overlay_disable_on_dice.
func _dice_popup_flow() -> void:
	dice = d.make_dice_popup(_root)
	await get_tree().process_frame
	check("the dice popup starts hidden", not d.dice_view(dice).visible)
	var root: DialogueNode = d.node("b_dice", "Prove it.", [
		d.skill_check("Try.", "Persuasion", "b_dice_end", "b_dice_end"), d.line("Bye.")])
	var end: DialogueNode = d.node("b_dice_end", "Hm.", [d.line("Bye.")])
	d.register_dialogue([root, end])
	d.start_dialogue(root, _pair())
	await get_tree().process_frame
	var said_before: int = d.transcript().size()
	d.choose("Try.")
	await get_tree().process_frame

	var view: Dictionary = d.dice_view(dice)
	check("a check shows the dice popup", view.visible)
	check("naming the check, with a Roll button",
		view.label == "Persuasion check" and view.button_visible and view.button_text == "Roll", str(view))
	var band: Dictionary = d.overlay_view(overlay)
	check("the band's rows are disabled while the dice are up",
		not band.rows.is_empty() and band.rows.all(func(r): return r.disabled), str(band.rows))
	check("so is Continue", band.continue_disabled)

	d.dice_press(dice)
	# The spin plays in real time (about 3 s), so wait on
	# the clock, not a frame count.
	var give_up: int = Time.get_ticks_msec() + 10000
	while not (d.dice_view(dice).button_visible and d.dice_view(dice).button_text == "Continue") and Time.get_ticks_msec() < give_up:
		await get_tree().process_frame
	view = d.dice_view(dice)
	check("after Roll the dice land and a verdict shows with Continue",
		view.button_text == "Continue" and view.label.contains(" vs "), str(view))
	check("the check still waits after the first click", d.transcript().size() == said_before and d.dialogue_active())

	d.dice_press(dice)
	await get_tree().process_frame
	check("the second click hides the popup", not d.dice_view(dice).visible)
	check("and lets the check finish", d.transcript().size() > said_before and d.current_node_id() == "b_dice_end")
	var rows: Array = d.overlay_view(overlay).rows
	check("the next node's rows are live again", not rows.is_empty() and not rows[0].disabled)
	d.end_dialogue()


## presenter_follow, dice_popup_late_pickup, dice_popup_abandons_on_end.
## A presenter follows Conversations for as long as it is in the tree: it
## stops listening when it leaves, and one that joins mid-conversation
## picks up the conversation already running instead of waiting for the
## next. And dice still on screen when their conversation ends are
## abandoned, not left to finish into a conversation that is gone.
func _dice_popup_follows_and_lets_go() -> void:
	check("setup: the popup in the tree is listening", d.hears_began(dice))
	_root.remove_child(dice)
	check("a presenter that leaves the tree stops listening", not d.hears_began(dice))

	var root: DialogueNode = d.node("b_late", "Prove it again.", [
		d.skill_check("Try.", "Persuasion", "b_dice_end", "b_dice_end"), d.line("Bye.")])
	d.register_dialogue([root])
	d.start_dialogue(root, _pair())
	await get_tree().process_frame
	_root.add_child(dice)
	check("and listens again once it is back", d.hears_began(dice))
	d.choose("Try.")
	await get_tree().process_frame
	check("joining mid-conversation, it still shows the check's dice",
		d.dice_view(dice).visible and d.dice_view(dice).button_text == "Roll", str(d.dice_view(dice)))

	d.dice_press(dice)
	await get_tree().process_frame
	d.end_dialogue()
	await get_tree().process_frame
	check("ending the conversation mid-tumble takes the dice down",
		not d.dice_view(dice).visible and not d.dice_view(dice).button_visible, str(d.dice_view(dice)))
	# Long enough for the abandoned tumble to have landed (the flow above
	# waits the same), so a roll that kept going would have put its
	# Continue back by now.
	var waited: int = 0
	while not d.dice_view(dice).button_visible and waited < 600:
		await get_tree().process_frame
		waited += 1
	check("and the abandoned roll never comes back to ask for Continue",
		not d.dice_view(dice).visible and not d.dice_view(dice).button_visible, str(d.dice_view(dice)))
	dice.queue_free()
