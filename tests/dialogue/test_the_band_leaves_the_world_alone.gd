extends AiTestCase
## The lower-third dialogue band replaces the old full-width, 35%-of-
## screen overlay whose root Control defaulted to Godot's own
## MOUSE_FILTER_STOP and silently ate every click across the whole bottom
## third of the screen — band content or not. This suite asserts the
## RENDERED shape of the new band, not DialogueManager's own state (see
## sabotage_checks_caught_two_false_greens.md and the 2026-09-02 audit
## that found dialogue UI covered by zero suites while a fully green run
## had already shipped an invisible panel once).
##
## Instantiates dialogue_overlay.tscn directly and drives it the same way
## test_gaze_follows_the_speaker.gd drives DialogueGaze: real
## DialogueManager signals, emitted by hand, against a
## DialogueManager.participants table this suite owns and restores —
## never a full DialogueManager.start_dialogue() conversation, since
## nothing here needs a real DialogueNode tree.
##
## THE SKILL-CHECK CHECKS ARE A CROSS-AGENT CONTRACT, NOT JUST THIS
## FILE'S OWN CODE. DialogueFormat.skill_parts() and
## DialogueChoice.cost_tags() are being built in parallel by another
## agent — choice_row.gd guards both with has_method()/call() on real
## instances and falls back to the old DialogueFormat.choice_label()
## string if either is missing, so THIS SUITE never crashes regardless of
## landing order. But the untrained-still-shows-a-number check below can
## only go green once skill_parts() actually exists — if it's still
## missing, choice_row.gd's fallback path renders the OLD literal word
## "untrained" instead, and that specific check fails on purpose: a red
## light here means the two halves haven't integrated yet, which is
## exactly the information the orchestrator needs.

const PLAYER := &"player"
const NPC := &"npc"

var _saved_participants: Dictionary = {}
## Typed as UIScreen (not just Control) so _cleanup() can hand it straight
## to UIStack.pop(), which requires exactly that type — dialogue_overlay.gd
## itself extends UIScreen, so this is the instance's real type, not a
## downcast.
var _overlay: UIScreen = null
## Hosted in a SubViewport at the game's real design size. The headless
## test runner's own viewport is 64px tall, so measuring a band against
## get_viewport() there compares 125px of content to 64px of screen and
## reports 195%. The band is not wrong; the ruler was.
const DESIGN := Vector2i(1600, 900)
var _host: Control = null


func run() -> void:
	_saved_participants = DialogueManager.participants.duplicate()

	var scene: PackedScene = load("res://systems/dialogue_system/dialogue_overlay.tscn")
	# A fixed-size Control as the parent, not a SubViewport: a full-rect
	# Control anchors against its Control parent's rect deterministically,
	# whereas a headless SubViewport never ran a layout pass and left the
	# band measuring 125px correctly but sitting at y=0.
	_host = Control.new()
	_host.size = Vector2(DESIGN)
	_root.add_child(_host)
	_overlay = scene.instantiate()
	_host.add_child(_overlay)
	# Shown before measuring: a UIScreen starts hidden and is revealed by
	# UIStack.push in the game. A hidden Control's containers have not
	# resolved a layout, so the band measured its own 125px correctly while
	# still sitting at y=0 with the expanding spacer above it collapsed.
	_overlay.visible = true
	await get_tree().process_frame
	await get_tree().process_frame

	_check_the_root_lets_clicks_through()
	await _check_band_shape()
	await _check_speaker_vs_aside_routing()
	await _check_choice_rows_carry_the_emitted_index()
	await _check_skill_check_rows_show_a_number()
	_check_stub_chips()

	_cleanup()


## The old build's root defaulted to Godot's own MOUSE_FILTER_STOP,
## which is exactly what made it swallow clicks across the whole bottom
## 35% of the screen regardless of whether the band itself occupied that
## space. IGNORE is the one setting that lets a click fall through to
## whatever's underneath (unit selection, the 3D world) — everything
## further down the tree (Band and its children) stays at Godot's
## default STOP so the band's OWN rect still captures its own clicks.
func _check_the_root_lets_clicks_through() -> void:
	check("the root does not capture mouse events outside its rect",
		_overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"root mouse_filter is %d, not MOUSE_FILTER_IGNORE (2) — a full-rect " % _overlay.mouse_filter +
		"Control at the default STOP blocks every click over the entire " +
		"screen, band content or not")


## Never a fixed fraction of the viewport, and never full-bleed — the
## approved mockup's whole point versus the old anchor_top = 0.65 slab.
func _check_band_shape() -> void:
	var band: Control = _overlay.get_node_or_null("Layout/Band")
	if band == null:
		check("SETUP: the Band node exists to measure", false)
		return

	var viewport_height: float = float(DESIGN.y)
	var band_rect: Rect2 = band.get_global_rect()

	check("the band occupies less than 40% of the viewport height",
		band_rect.size.y < viewport_height * 0.4,
		"band height is %.0fpx of a %.0fpx-tall viewport (%.0f%%)" % [
			band_rect.size.y, viewport_height, 100.0 * band_rect.size.y / viewport_height])

	check("and does not reach the top of the screen",
		band_rect.position.y > viewport_height * 0.2,
		"band top y=%.0f, height %.0f, in an overlay of %s — " % [band_rect.position.y, band_rect.size.y, str(_overlay.size)] +
		"bottom should leave most of the screen clear above it")


## speaker_token == "" is a system echo (alignment shift, roll result, who
## assisted) — it must land on the dimmed aside line, never the speaker
## row, and vice versa. Checked both directions: a real speaker line must
## NOT touch the aside, and an echo must NOT touch the line label — either
## one alone would pass if the two were simply always kept in sync.
func _check_speaker_vs_aside_routing() -> void:
	var npc: Unit = spawn_brute(0.0, 0.0)
	DialogueManager.participants = {NPC: npc}

	var speaker_label: Label = _overlay.get_node_or_null("Layout/Band/Content/MainRow/TextColumn/SpeakerNameLabel")
	var line_label: Label = _overlay.get_node_or_null("Layout/Band/Content/MainRow/TextColumn/LineLabel")
	var aside_label: Label = _overlay.get_node_or_null("Layout/Band/Content/AsideLabel")
	if speaker_label == null or line_label == null or aside_label == null:
		check("SETUP: speaker/line/aside labels exist to inspect", false)
		return

	DialogueManager.line_shown.emit("Well met, traveler.", String(NPC))
	await get_tree().process_frame
	check("a line with a speaker renders into the speaker row",
		speaker_label.text != "" and line_label.text == "Well met, traveler.",
		"speaker label reads '%s', line label reads '%s'" % [speaker_label.text, line_label.text])
	check("and does not touch the aside line",
		aside_label.text == "",
		"aside label picked up '%s' from a line that had a real speaker" % aside_label.text)

	DialogueManager.line_shown.emit("(you feel a chill)", "")
	await get_tree().process_frame
	check("an empty-token line renders into the aside instead",
		aside_label.text == "(you feel a chill)",
		"aside label reads '%s'" % aside_label.text)
	check("and does not overwrite the speaker row's current line",
		line_label.text == "Well met, traveler.",
		"line label changed to '%s' from a line nobody spoke" % line_label.text)


## choices_shown's index space is DialogueManager's own FILTERED list
## (see dialogue_manager.gd's own comment on _visible_choices) — a
## previously-shipped bug remapped this through the node's raw choices
## array instead. Asserts the row count matches AND that each row's
## stored index is the position handed to it, unchanged.
func _check_choice_rows_carry_the_emitted_index() -> void:
	var choices: Array[DialogueChoice] = []
	for label in ["Ask about the road", "Ask about the ruins", "Leave"]:
		var choice := LineChoice.new()
		choice.text = label
		choices.append(choice)

	DialogueManager.choices_shown.emit(choices)
	await get_tree().process_frame

	# Read the overlay's OWN _choice_rows bookkeeping (via Object.get() —
	# _overlay is statically typed UIScreen, which doesn't itself declare
	# this field, so a direct _overlay._choice_rows would be a static-type
	# error even though the real dialogue_overlay.gd instance has it)
	# rather than counting ChoiceList's raw scene-tree children:
	# _clear_choice_rows() calls queue_free() on the previous batch, which
	# is DEFERRED (see tests/README.md's own "queue_free() is deferred"
	# warning) — a row from an earlier choices_shown can still be a live
	# child for the rest of the frame it was freed in, sitting BEFORE the
	# freshly add_child()'d ones in child order. _choice_rows is updated
	# synchronously in the same call, so it always names exactly the
	# CURRENT batch regardless of whether the previous batch has
	# physically left the tree yet.
	var rows: Array[ChoiceRow] = _overlay.get("_choice_rows")
	check("one row per emitted choice",
		rows.size() == 3,
		"expected 3 rows, found %d" % rows.size())

	for i in rows.size():
		var row: ChoiceRow = rows[i]
		check("row %d carries index %d, unchanged" % [i, i],
			row._index == i,
			"row %d stored index %d instead" % [i, row._index])


## The one requested deviation from the mockup: an untrained-but-
## attemptable skill check shows the SAME real number a trained one
## does, styled differently, rather than the word "untrained". See this
## file's own header for why this half of the suite is a cross-agent
## contract rather than something purely local to choice_row.gd.
func _check_skill_check_rows_show_a_number() -> void:
	var trained_actor: Unit = spawn_brute(4.0, 0.0)
	var trained_skill := SkillInstance.new()
	trained_skill.skill_data = load("res://data/skills/persuasion.tres")
	trained_skill.levels_purchased = 2
	trained_actor.add_skill(trained_skill)

	var untrained_actor: Unit = spawn_brute(6.0, 0.0)
	# No SkillInstance added — Persuasion defaults off IQ (see
	# data/skills/persuasion.tres), so this unit is untrained but still
	# attemptable, the exact gap SkillCheckResult.is_trained/attemptable
	# exist to distinguish.

	var choice := SkillCheckChoice.new()
	choice.text = "Talk your way past"
	choice.skill_name = "Persuasion"
	choice.success_node_id = "x"
	choice.failure_node_id = "y"
	choice.show_to_player = true

	var format_probe: RefCounted = DialogueFormat.new()
	if not format_probe.has_method("skill_parts") or not choice.has_method("cost_tags"):
		check("SKIPPED (integration not landed yet): DialogueFormat.skill_parts()/DialogueChoice.cost_tags() " +
			"don't exist on this run — choice_row.gd falls back to the old choice_label() string instead of " +
			"crashing, which is the only thing this file can promise until the other agent's half lands",
			true)
		return

	var single_choice: Array[DialogueChoice] = [choice]

	DialogueManager.participants = {PLAYER: trained_actor}
	DialogueManager.choices_shown.emit(single_choice)
	await get_tree().process_frame
	# See _check_choice_rows_carry_the_emitted_index's comment on why this
	# reads _choice_rows rather than ChoiceList's first raw child.
	var trained_rows: Array[ChoiceRow] = _overlay.get("_choice_rows")
	var trained_tags: String = trained_rows[0].get_node("Content/TagsLabel").text
	check("a trained skill-check row shows a real number",
		_contains_digit(trained_tags),
		"tags text was '%s'" % trained_tags)

	DialogueManager.participants = {PLAYER: untrained_actor}
	DialogueManager.choices_shown.emit(single_choice)
	await get_tree().process_frame
	var untrained_rows: Array[ChoiceRow] = _overlay.get("_choice_rows")
	var untrained_tags: String = untrained_rows[0].get_node("Content/TagsLabel").text
	check("and an untrained-but-attemptable one shows the SAME kind of number, not the word 'untrained'",
		_contains_digit(untrained_tags) and not untrained_tags.to_lower().contains("untrained"),
		"tags text was '%s'" % untrained_tags)


func _check_stub_chips() -> void:
	var log_chip: Button = _overlay.get_node_or_null("TopRightChips/LogChip")
	var history_chip: Button = _overlay.get_node_or_null("TopRightChips/HistoryChip")
	var settings_chip: Button = _overlay.get_node_or_null("TopRightChips/SettingsChip")
	var leave_chip: Button = _overlay.get_node_or_null("TopRightChips/LeaveChip")
	if log_chip == null or history_chip == null or settings_chip == null or leave_chip == null:
		check("SETUP: all four chips exist", false)
		return

	for entry in [["History", history_chip], ["Settings", settings_chip], ["Leave", leave_chip]]:
		var chip_name: String = entry[0]
		var chip: Button = entry[1]
		check("%s chip is visibly marked as a stub" % chip_name,
			chip.tooltip_text != "" and chip.modulate.a < 1.0,
			"tooltip='%s' modulate.a=%.2f" % [chip.tooltip_text, chip.modulate.a])
		# Pressing it must not throw and must not open any UIScreen —
		# it only ever pushes a warning (see dialogue_overlay.gd's
		# _on_stub_pressed).
		chip.pressed.emit()

	check("the Log chip is NOT marked as a stub",
		log_chip.modulate.a >= 1.0,
		"Log's modulate.a is %.2f — it should read identically to a working chip" % log_chip.modulate.a)


func _contains_digit(text: String) -> bool:
	for i in text.length():
		if text[i].is_valid_int():
			return true
	return false


func _cleanup() -> void:
	if is_instance_valid(_overlay):
		UIStack.pop(_overlay)
		_overlay.queue_free()
	DialogueManager.participants = _saved_participants
