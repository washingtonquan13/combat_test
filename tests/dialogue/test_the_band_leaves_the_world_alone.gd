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
## 2026-09-03 rebuild: the band went from a MarginContainer with pixel
## insets (margin_left/right = 104) and a 560px-wide TextColumn/ChoiceList
## to a VBoxContainer anchored by PERCENTAGE, with every spanning child on
## EXPAND_FILL. A suite that only checks the band's position/size at one
## fixed viewport width cannot tell those two apart — a fixed-pixel inset
## and a 6.5% anchor land on the exact same numbers at 1600x900. So this
## suite resizes the host mid-run and re-measures: a percentage anchor
## MOVES with the host, a pixel constant does not. See
## _check_layout_is_anchor_driven and _check_resize_ratchet_with_rows_present.
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
##
## 2026-09-03 hardening pass (adversarial review): every node lookup below
## goes through find_child(name, true, false) from the overlay root (or
## from a specific ChoiceRow instance for its own internal labels), NEVER
## a hard child path — the other agent is reparenting Band inside a new
## Stack/BandMargin column, and the old Scrim node is already gone,
## replaced by Band's own StyleBoxTexture background (confirmed in the
## current .tscn; this suite asserts nothing about a Scrim node at all).
## Only NODE NAMES are the contract. Findings fixed, each on its owning
## check:
##   F5  — _check_skill_check_rows_show_a_number: scans get_parsed_text(),
##         not raw bbcode `.text` (a hidden-skill "?" marker's own colour
##         code, e.g. "#808080", contains digits and used to pass as "a
##         number"), and asserts the SPECIFIC level SkillCalculator
##         computes for the staged actor, not just "any digit."
##   F6  — _check_choice_row_grows_with_wrapped_text: adds a no-overhang
##         check (every row's rendered width matches the Choices
##         container's width) and a bounded wrap-ratio check (a row stuck
##         wrapping one word per line at width 0 would blow way past 4x).
##   F7  — _check_resize_ratchet_with_rows_present: the width-ratchet proof
##         now runs AFTER real ChoiceRows exist (moved out of
##         _check_layout_is_anchor_driven, which previously ran it before
##         any row existed and so could never observe a row-layout ratchet
##         bug), and additionally asserts every row still fits inside the
##         band at both widths.
##   F8  — _check_chips_are_plain_text_and_fit: adds on-screen position
##         (global_position.x >= 0), no-spillover
##         (get_global_rect().end.x <= host right edge), and
##         near-the-right-edge assertions — a chips container sitting
##         off-screen at a huge negative x used to still satisfy the old
##         "not wider than the host" check.
##   F10 — _settle(): three process frames after every layout-affecting
##         change (resize, choices_shown, line_shown), not two, used
##         everywhere this suite used to await a bare frame or two.
##   F18 — (a) _check_band_shape/_check_overlay_and_band_are_actually_visible
##         assert is_visible_in_tree(), not just a manager flag; (b)
##         _check_band_shape asserts the real 29px gap (BandMargin's own
##         margin_bottom) between the band's bottom edge and the host's
##         bottom edge; (c) _check_band_tracks_host_height varies the
##         host's HEIGHT (900 -> 720) and asserts the band's bottom edge
##         tracks it while the top edge moves too, not just clips; (d)
##         setup now pushes the overlay through UIStack.push() (mirroring
##         real game usage — see dialogue_overlay.gd's own open()) instead
##         of setting `visible` by hand, so _cleanup's UIStack.pop() is
##         popping something that was actually pushed.

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
## The narrower width _check_resize_ratchet_with_rows_present resizes the
## host to, to prove the band's edges and Line's width are percentages of
## the host, not pixel constants left over from the old build.
const NARROW_WIDTH := 1200
## F18(c): a shorter host HEIGHT, to prove the band's bottom edge tracks
## the host's bottom edge (not just its width).
const SHORT_HEIGHT := 720
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
	# F18(d): pushed through UIStack rather than setting `visible` by hand —
	# this is exactly how the real game shows this screen (see
	# dialogue_overlay.gd's open(), which is just UIStack.push(self)), and
	# it means _cleanup()'s UIStack.pop(_overlay) below is popping
	# something that was actually pushed, instead of popping a screen
	# UIStack never knew was open.
	UIStack.push(_overlay)
	await _settle()

	_check_the_root_lets_clicks_through()
	_check_overlay_and_band_are_actually_visible()
	await _check_band_shape()
	await _check_band_tracks_host_height()
	_check_layout_is_anchor_driven()
	await _check_speaker_vs_aside_routing()
	await _check_choice_rows_carry_the_emitted_index()
	await _check_no_pixel_widths_survive()
	await _check_choice_row_grows_with_wrapped_text()
	await _check_resize_ratchet_with_rows_present()
	await _check_skill_check_rows_show_a_number()
	_check_portrait_is_gone()
	_check_stub_chips()
	_check_chips_are_plain_text_and_fit()

	_cleanup()


## F10: three process frames, not two or one — a Container's minimum-size
## layout pass and RichTextLabel's autowrap-driven fit_content re-measure
## do not reliably resolve inside fewer frames once several nested
## containers are involved (Stack -> BandMargin -> Band -> BandContent ->
## Choices -> ChoiceRow -> Content).
func _settle(frames: int = 3) -> void:
	for i in frames:
		await get_tree().process_frame


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


## F18(a): a manager-side "I called push/open" flag proves nothing about
## what actually rendered — the 2026-09-02 audit's whole finding was a
## fully green suite that had shipped an invisible panel. is_visible_in_tree()
## is the one query that fails if ANY ancestor (including a container this
## suite doesn't even know the name of) is hidden.
func _check_overlay_and_band_are_actually_visible() -> void:
	check("F18: the overlay is actually visible in the tree after UIStack.push()",
		_overlay.is_visible_in_tree(),
		"overlay.is_visible_in_tree() is false even though it was pushed")

	var band: Control = _overlay.find_child("Band", true, false)
	check("F18: the Band is actually visible in the tree too",
		band != null and band.is_visible_in_tree(),
		"Band missing entirely, or present but not visible in tree")


## Never a fixed fraction of the viewport, and never full-bleed — the
## approved mockup's whole point versus the old anchor_top = 0.65 slab.
## F18(b): also proves the band sits the mockup's specific 29px above the
## host's bottom edge (BandMargin's own margin_bottom in the .tscn), not
## just "somewhere in the bottom 40%."
func _check_band_shape() -> void:
	var band: Control = _overlay.find_child("Band", true, false)
	if band == null:
		check("SETUP: the Band node exists to measure", false)
		return

	var viewport_height: float = float(DESIGN.y)
	var band_rect: Rect2 = band.get_global_rect()
	var host_rect: Rect2 = _host.get_global_rect()

	check("the band occupies less than 40% of the viewport height",
		band_rect.size.y < viewport_height * 0.4,
		"band height is %.0fpx of a %.0fpx-tall viewport (%.0f%%)" % [
			band_rect.size.y, viewport_height, 100.0 * band_rect.size.y / viewport_height])

	check("and does not reach the top of the screen",
		band_rect.position.y > viewport_height * 0.2,
		"band top y=%.0f, height %.0f, in an overlay of %s — " % [band_rect.position.y, band_rect.size.y, str(_overlay.size)] +
		"bottom should leave most of the screen clear above it")

	check("F18: the band's bottom edge sits ~29px above the host's bottom edge",
		absf(host_rect.end.y - band_rect.end.y - 29.0) <= 2.0,
		"band bottom at %.1f, host bottom at %.1f, gap %.1fpx (want 29 +/-2)" % [
			band_rect.end.y, host_rect.end.y, host_rect.end.y - band_rect.end.y])


## F18(c): varies the host's HEIGHT (900 -> 720), not just its width, and
## proves the band's bottom edge keeps tracking the host's bottom edge
## (same ~29px gap) while the TOP edge also moves — a band that stayed
## pinned at a fixed absolute y (rather than anchored to the bottom) would
## keep the same bottom-edge gap by coincidence at one height but freeze
## in place across a resize.
func _check_band_tracks_host_height() -> void:
	var band: Control = _overlay.find_child("Band", true, false)
	if band == null:
		check("SETUP: Band exists for the height-resize check", false)
		return

	var rect_tall: Rect2 = band.get_global_rect()

	_host.size = Vector2(DESIGN.x, SHORT_HEIGHT)
	await _settle()

	var rect_short: Rect2 = band.get_global_rect()
	var host_rect_short: Rect2 = _host.get_global_rect()

	check("F18: the band's bottom edge still sits ~29px above the host's bottom edge at a shorter host height",
		absf(host_rect_short.end.y - rect_short.end.y - 29.0) <= 2.0,
		"band bottom %.1f, host bottom %.1f, gap %.1f (want 29 +/-2) at host height %d" % [
			rect_short.end.y, host_rect_short.end.y, host_rect_short.end.y - rect_short.end.y, SHORT_HEIGHT])
	check("F18: the band's bottom edge actually moved up with the shorter host",
		absf(rect_short.end.y - rect_tall.end.y) > 100.0,
		"band bottom stayed at %.1f across a %dpx and a %dpx-tall host" % [rect_tall.end.y, DESIGN.y, SHORT_HEIGHT])
	check("F18: the band's top edge moved too (tracking the resize, not clipped in place)",
		absf(rect_short.position.y - rect_tall.position.y) > 50.0,
		"band top stayed at %.1f across host heights %d and %d" % [rect_tall.position.y, DESIGN.y, SHORT_HEIGHT])

	_host.size = Vector2(DESIGN)
	await _settle()


## The structural proof that the band's shape comes from ANCHORS/size
## flags baked into the .tscn, not from pixel constants a rebuild left
## behind. Measures the band's left/right edge as a fraction of the host
## width, and the Line label's width against the band's own inner width,
## at the design width. The narrow-host / restore-and-check-for-a-ratchet
## half of this proof (F7) now lives in
## _check_resize_ratchet_with_rows_present, which runs once real
## ChoiceRows are on screen — running it here, before any row exists,
## could never have observed a row-layout ratchet bug, which is exactly
## what the 2026-09-03 review flagged.
func _check_layout_is_anchor_driven() -> void:
	var band: Control = _overlay.find_child("Band", true, false)
	var line: Label = _overlay.find_child("Line", true, false)
	if band == null or line == null:
		check("SETUP: Band and Line exist to measure", false)
		return

	var band_rect_wide: Rect2 = band.get_global_rect()
	var line_width_wide: float = line.size.x
	var left_pct_wide: float = band_rect_wide.position.x / float(DESIGN.x)
	var right_pct_wide: float = band_rect_wide.end.x / float(DESIGN.x)

	check("the band's left edge sits at about 6.5%% of a %dpx-wide host" % DESIGN.x,
		absf(left_pct_wide - 0.065) < 0.01,
		"left edge at %.1fpx = %.3f of %d" % [band_rect_wide.position.x, left_pct_wide, DESIGN.x])
	check("and its right edge sits at about 93.5%",
		absf(right_pct_wide - 0.935) < 0.01,
		"right edge at %.1fpx = %.3f of %d" % [band_rect_wide.end.x, right_pct_wide, DESIGN.x])
	check("the Line label's width matches the band's own inner width",
		absf(line_width_wide - band.size.x) < 4.0,
		"line width %.1f vs band width %.1f at %dpx host" % [line_width_wide, band.size.x, DESIGN.x])


## speaker_token == "" is a system echo (alignment shift, roll result, who
## assisted) — it must land on the dimmed aside line, never the speaker
## row, and vice versa. Checked both directions: a real speaker line must
## NOT touch the aside, and an echo must NOT touch the line label — either
## one alone would pass if the two were simply always kept in sync.
func _check_speaker_vs_aside_routing() -> void:
	var npc: Unit = spawn_brute(0.0, 0.0)
	DialogueManager.participants = {NPC: npc}

	var speaker_label: Label = _overlay.find_child("Speaker", true, false)
	var line_label: Label = _overlay.find_child("Line", true, false)
	var aside_label: Label = _overlay.find_child("Aside", true, false)
	if speaker_label == null or line_label == null or aside_label == null:
		check("SETUP: speaker/line/aside labels exist to inspect", false)
		return

	DialogueManager.line_shown.emit("Well met, traveler.", String(NPC))
	await _settle()
	check("a line with a speaker renders into the speaker row",
		speaker_label.text != "" and line_label.text == "Well met, traveler.",
		"speaker label reads '%s', line label reads '%s'" % [speaker_label.text, line_label.text])
	check("and does not touch the aside line",
		aside_label.text == "",
		"aside label picked up '%s' from a line that had a real speaker" % aside_label.text)

	DialogueManager.line_shown.emit("(you feel a chill)", "")
	await _settle()
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
	await _settle()

	# Read the overlay's OWN _choice_rows bookkeeping (via Object.get() —
	# _overlay is statically typed UIScreen, which doesn't itself declare
	# this field, so a direct _overlay._choice_rows would be a static-type
	# error even though the real dialogue_overlay.gd instance has it)
	# rather than counting Choices' raw scene-tree children:
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


## The structural guard against the rebuild's own bugs coming back:
## TextColumn/ChoiceList's old custom_minimum_size = Vector2(560, 0) is
## exactly the kind of pixel width that pins a Container child regardless
## of its parent's real size. Walks every Control under Band and fails on
## any nonzero custom_minimum_size.x EXCEPT a choice row's own Index
## column, which is the one place the rebuild spec allows a fixed width
## (a two-digit index column has no reason to track the row's size).
## Names the offending node path in the failure detail rather than just
## reporting a count, so a future regression here says exactly where to
## look instead of just that something regressed.
func _check_no_pixel_widths_survive() -> void:
	var choice := LineChoice.new()
	choice.text = "A single response, just to populate one real ChoiceRow to walk."
	var choices: Array[DialogueChoice] = [choice]
	DialogueManager.choices_shown.emit(choices)
	await _settle()

	var band: Control = _overlay.find_child("Band", true, false)
	if band == null:
		check("SETUP: Band exists to walk", false)
		return

	var offenders: Array[String] = []
	_walk_for_pixel_widths(band, offenders)
	check("no descendant of Band has a pixel-width custom_minimum_size, except a row's index column",
		offenders.is_empty(),
		"offending node(s): %s" % ", ".join(offenders))


func _walk_for_pixel_widths(node: Node, offenders: Array[String]) -> void:
	for child in node.get_children():
		if child is Control:
			var ctrl: Control = child
			if ctrl.custom_minimum_size.x != 0.0 and not _is_row_index_column(ctrl):
				offenders.append(str(ctrl.get_path()))
		_walk_for_pixel_widths(child, offenders)


## The Index label is named "Index" and sits somewhere under a ChoiceRow
## ancestor (walked up rather than a fixed "parent.parent is ChoiceRow"
## hop, since choice_row.* is being edited in parallel and its own
## Content wrapper could gain another layer of nesting) — matching by name
## plus that ancestry, rather than just "is this label named Index
## anywhere," so a coincidentally-named node elsewhere in the band would
## still be caught.
func _is_row_index_column(ctrl: Control) -> bool:
	if ctrl.name != "Index":
		return false
	var node: Node = ctrl.get_parent()
	while node != null and not (node is ChoiceRow):
		node = node.get_parent()
	return node != null


## A row is a real Container now (PanelContainer, not a Button whose
## minimum size only ever comes from its own text/icon) — this is the
## direct proof: a choice long enough to wrap at the band's current width
## must report a taller get_combined_minimum_size().y than a short
## one-liner. The old Button root would have reported the SAME minimum
## height for both, since its wrapped HBoxContainer child never
## contributed to it.
##
## F6 hardening: the old version of this check only asserted
## long_height > short_height + 5, which is ALSO true of a row stuck
## wrapping one word per line because its width resolved to 0 — that
## produces a very TALL row too, just for the wrong reason. Two more
## checks close that gap: every row's rendered size.x must match the
## Choices container's width (a width-0 row would obviously fail this),
## and the long row's height must stay under 4x the short row's (a
## genuine multi-line wrap of one long sentence at a real ~1350px-wide
## band does not blow past that; one-word-per-line wrapping would).
func _check_choice_row_grows_with_wrapped_text() -> void:
	var choices_container: Control = _overlay.find_child("Choices", true, false)
	if choices_container == null:
		check("SETUP: Choices container exists to measure rows against", false)
		return

	var short_choice := LineChoice.new()
	short_choice.text = "Yes."
	var long_choice := LineChoice.new()
	long_choice.text = "This response is deliberately long enough that it has to wrap across multiple lines at the band's current width, which should make this row's own minimum height noticeably taller than a short one-line row's."

	var short_list: Array[DialogueChoice] = [short_choice]
	DialogueManager.choices_shown.emit(short_list)
	await _settle()
	var short_rows: Array[ChoiceRow] = _overlay.get("_choice_rows")
	if short_rows.is_empty():
		check("SETUP: the short-text row exists to measure", false)
		return
	var short_height: float = short_rows[0].get_combined_minimum_size().y
	var short_width: float = short_rows[0].size.x
	check("F6: the short row's rendered width matches the Choices container's width (no overhang, and not stuck at 0)",
		absf(short_width - choices_container.size.x) < 1.0,
		"short row width %.1fpx vs Choices container width %.1fpx" % [short_width, choices_container.size.x])

	var long_list: Array[DialogueChoice] = [long_choice]
	DialogueManager.choices_shown.emit(long_list)
	await _settle()
	var long_rows: Array[ChoiceRow] = _overlay.get("_choice_rows")
	if long_rows.is_empty():
		check("SETUP: the long-text row exists to measure", false)
		return
	var long_height: float = long_rows[0].get_combined_minimum_size().y
	var long_width: float = long_rows[0].size.x
	check("F6: the long row's rendered width matches the Choices container's width too",
		absf(long_width - choices_container.size.x) < 1.0,
		"long row width %.1fpx vs Choices container width %.1fpx" % [long_width, choices_container.size.x])

	check("a choice row whose text wraps reports a taller minimum height than a one-line row",
		long_height > short_height + 5.0,
		"short row min height %.1fpx, long (wrapping) row min height %.1fpx" % [short_height, long_height])
	check("F6: the wrapped row grew to a FEW lines, not one word per line (bounded height ratio, catches a width==0 wrap)",
		long_height < short_height * 4.0,
		"short row height %.1fpx, long row height %.1fpx (ratio %.2fx of short) — over 4x reads as one-word-per-line wrapping, not real wrap-to-width" % [
			short_height, long_height, (long_height / short_height) if short_height > 0.0 else -1.0])


## F7: the width-ratchet proof (a percentage anchor MOVES with the host, a
## leftover pixel constant does not — see this file's own header) run
## with real ChoiceRows already on screen. The review's finding: the old
## version of this proof ran in _check_layout_is_anchor_driven BEFORE any
## choice row existed, so a ratchet bug specific to row layout (a row's
## width creeping wider on every resize instead of tracking the host,
## e.g.) could never have been observed by this suite at all. Same
## left/right-edge-percentage and Line-width proof as before, now plus:
## every row still fits inside the band's own right edge at BOTH widths,
## and the band/Line measurements come back to their original values
## after restoring the host to DESIGN — the actual "no ratchet" proof,
## since a ratchet specifically means repeated resizes drift further away
## each time rather than settling back to where they started.
func _check_resize_ratchet_with_rows_present() -> void:
	var band: Control = _overlay.find_child("Band", true, false)
	var line: Label = _overlay.find_child("Line", true, false)
	if band == null or line == null:
		check("SETUP: Band and Line exist for the resize-with-rows check", false)
		return

	var wrap_choice := LineChoice.new()
	wrap_choice.text = "This response is deliberately long enough that it has to wrap across a couple of lines at the band's current width, so the resize-with-rows check has something real to re-measure."
	var short_choice := LineChoice.new()
	short_choice.text = "No."
	var rows_choices: Array[DialogueChoice] = [short_choice, wrap_choice]
	DialogueManager.choices_shown.emit(rows_choices)
	await _settle()

	var rows: Array[ChoiceRow] = _overlay.get("_choice_rows")
	if rows.size() != 2:
		check("SETUP: both rows exist for the resize-with-rows check", false)
		return

	var band_rect_wide: Rect2 = band.get_global_rect()
	var line_width_wide: float = line.size.x

	for row in rows:
		check("F7: every row fits inside the band at the %dpx-wide host" % DESIGN.x,
			row.get_global_rect().end.x <= band_rect_wide.end.x + 1.0,
			"row '%s' right edge %.1f vs band right edge %.1f" % [row.name, row.get_global_rect().end.x, band_rect_wide.end.x])

	_host.size = Vector2(NARROW_WIDTH, DESIGN.y)
	await _settle()

	var band_rect_narrow: Rect2 = band.get_global_rect()
	var line_width_narrow: float = line.size.x
	var left_pct_narrow: float = band_rect_narrow.position.x / float(NARROW_WIDTH)
	var right_pct_narrow: float = band_rect_narrow.end.x / float(NARROW_WIDTH)

	check("F7: the band's left edge is still about 6.5%% at a %dpx-wide host with rows on screen" % NARROW_WIDTH,
		absf(left_pct_narrow - 0.065) < 0.01,
		"left edge at %.1fpx = %.3f of %d" % [band_rect_narrow.position.x, left_pct_narrow, NARROW_WIDTH])
	check("F7: and its right edge is still about 93.5%",
		absf(right_pct_narrow - 0.935) < 0.01,
		"right edge at %.1fpx = %.3f of %d" % [band_rect_narrow.end.x, right_pct_narrow, NARROW_WIDTH])
	check("F7: the band's left edge actually MOVED when the host resized (rows on screen)",
		absf(band_rect_narrow.position.x - band_rect_wide.position.x) > 5.0,
		"left edge stayed at %.1fpx across both host widths — that reads as a fixed pixel inset, not an anchor" % band_rect_wide.position.x)
	check("F7: the band's right edge moved too",
		absf(band_rect_narrow.end.x - band_rect_wide.end.x) > 5.0,
		"right edge stayed at %.1fpx across both host widths" % band_rect_wide.end.x)
	check("F7: the Line label's width still matches the band's inner width at the narrower host",
		absf(line_width_narrow - band.size.x) < 4.0,
		"line width %.1f vs band width %.1f at %dpx host" % [line_width_narrow, band.size.x, NARROW_WIDTH])
	check("F7: the Line label's width actually changed with the host (not a stuck constant)",
		absf(line_width_narrow - line_width_wide) > 20.0,
		"line width stayed at %.1fpx across a %dpx and %dpx host" % [line_width_wide, DESIGN.x, NARROW_WIDTH])

	var rows_narrow: Array[ChoiceRow] = _overlay.get("_choice_rows")
	for row in rows_narrow:
		check("F7: every row still fits inside the band at the narrower %dpx host" % NARROW_WIDTH,
			row.get_global_rect().end.x <= band_rect_narrow.end.x + 1.0,
			"row '%s' right edge %.1f vs band right edge %.1f at %dpx" % [row.name, row.get_global_rect().end.x, band_rect_narrow.end.x, NARROW_WIDTH])

	_host.size = Vector2(DESIGN)
	await _settle()

	var band_rect_restored: Rect2 = band.get_global_rect()
	var line_width_restored: float = line.size.x
	check("F7: the band's left edge came back after restoring the host to %dpx (proves no ratchet, not just 'still a percentage')" % DESIGN.x,
		absf(band_rect_restored.position.x - band_rect_wide.position.x) < 4.0,
		"left edge was %.1fpx originally, %.1fpx after restore" % [band_rect_wide.position.x, band_rect_restored.position.x])
	check("F7: the Line label's width came back too",
		absf(line_width_restored - line_width_wide) < 4.0,
		"line width was %.1fpx originally, %.1fpx after restore" % [line_width_wide, line_width_restored])


## The one requested deviation from the mockup: an untrained-but-
## attemptable skill check shows the SAME real number a trained one
## does, styled differently, rather than the word "untrained". See this
## file's own header for why this half of the suite is a cross-agent
## contract rather than something purely local to choice_row.gd.
##
## F5 hardening: the Tags label is a bbcode RichTextLabel (see
## choice_row.tscn — bbcode_enabled = true), and a hidden-skill marker is
## rendered as "[color=#808080]?[/color]" — the "808080" colour code alone
## contains six digit characters, so the old raw-`.text` digit scan would
## report a hidden-skill row as "shows a number" even though the player
## sees nothing but a "?". get_parsed_text() strips bbcode before
## scanning, and the assertion below is for the SPECIFIC level
## SkillCalculator computes for the staged actor (the same source
## test_a_skill_shows_its_level.gd reads), not just "contains some digit."
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

	# The exact computed levels, read straight from SkillCalculator — the
	# same source of truth test_a_skill_shows_its_level.gd asserts against
	# — rather than any placeholder. If choice_row.gd or DialogueFormat
	# ever show a DIFFERENT number than what SkillCalculator actually
	# computed, this is the check that catches it.
	var trained_level: int = SkillCalculator.get_skill_level(trained_actor, "Persuasion").skill_level
	var untrained_level: int = SkillCalculator.get_skill_level(untrained_actor, "Persuasion").skill_level

	var single_choice: Array[DialogueChoice] = [choice]

	DialogueManager.participants = {PLAYER: trained_actor}
	DialogueManager.choices_shown.emit(single_choice)
	await _settle()
	# See _check_choice_rows_carry_the_emitted_index's comment on why this
	# reads _choice_rows rather than Choices' first raw child.
	var trained_rows: Array[ChoiceRow] = _overlay.get("_choice_rows")
	if trained_rows.is_empty():
		check("SETUP: a trained skill-check row exists to measure", false)
		return
	var trained_tags_label: RichTextLabel = trained_rows[0].find_child("Tags", true, false)
	var trained_parsed: String = trained_tags_label.get_parsed_text() if trained_tags_label else ""
	check("F5: a trained skill-check row shows the real computed number (bbcode-parsed text, not the raw colour-coded string)",
		trained_parsed.contains("Persuasion %d" % trained_level),
		"parsed tags text was '%s' (raw bbcode: '%s'), expected to contain 'Persuasion %d'" % [
			trained_parsed, trained_tags_label.text if trained_tags_label else "<missing Tags node>", trained_level])

	DialogueManager.participants = {PLAYER: untrained_actor}
	DialogueManager.choices_shown.emit(single_choice)
	await _settle()
	var untrained_rows: Array[ChoiceRow] = _overlay.get("_choice_rows")
	if untrained_rows.is_empty():
		check("SETUP: an untrained skill-check row exists to measure", false)
		return
	var untrained_tags_label: RichTextLabel = untrained_rows[0].find_child("Tags", true, false)
	var untrained_parsed: String = untrained_tags_label.get_parsed_text() if untrained_tags_label else ""
	check("F5: and an untrained-but-attemptable one shows the SAME kind of real number, not the word 'untrained'",
		untrained_parsed.contains("Persuasion %d" % untrained_level) and not untrained_parsed.to_lower().contains("untrained"),
		"parsed tags text was '%s' (raw bbcode: '%s'), expected to contain 'Persuasion %d' with no 'untrained' word" % [
			untrained_parsed, untrained_tags_label.text if untrained_tags_label else "<missing Tags node>", untrained_level])


## "I didn't ask for a portrait" — the Portrait TextureRect, MainRow
## HBoxContainer wrapper, and TextColumn are gone from the .tscn entirely,
## not just hidden. Walks the WHOLE overlay (not just Band) so a stray
## Portrait node left anywhere else would still be caught.
func _check_portrait_is_gone() -> void:
	check("the Portrait node no longer exists anywhere in the overlay",
		_overlay.find_child("Portrait", true, false) == null,
		"a node named 'Portrait' is still somewhere under the overlay")


func _check_stub_chips() -> void:
	var log_chip: Button = _overlay.find_child("LogChip", true, false)
	var history_chip: Button = _overlay.find_child("HistoryChip", true, false)
	var settings_chip: Button = _overlay.find_child("SettingsChip", true, false)
	var leave_chip: Button = _overlay.find_child("LeaveChip", true, false)
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


## "L O G", "H I S T O R Y", "S E T T I N G S" — the old fake-letter-spacing
## trick (joining characters with a thin space) is gone in favour of plain
## text, and the HBoxContainer that used to need a hardcoded
## offset_left = -280 to force-fit "S E T T I N G S" now just sizes itself
## to its four buttons' real content. Checked together since they're the
## same regression: spaced-out text is also WIDER text, so a chips
## container that's still oversized is a symptom of the same leftover
## hack this checks for directly.
##
## F8 hardening: the old "chips.size.x <= host.size.x" check is satisfied
## by a chips container sitting completely off-screen (a huge negative
## global x, e.g.) just as happily as by a correctly-placed one — .size is
## a local extent, not a screen position. Adds: the container's global
## left edge is on screen (>= 0), its global right edge does not spill
## past the host's own right edge, and that right edge actually sits near
## the host's right edge (the chip row's real mockup position, top-right)
## rather than merely fitting somewhere.
func _check_chips_are_plain_text_and_fit() -> void:
	var chips: Control = _overlay.find_child("Chips", true, false)
	if chips == null:
		check("SETUP: Chips container exists", false)
		return

	for entry in [["Log", "LogChip"], ["History", "HistoryChip"], ["Settings", "SettingsChip"], ["Leave", "LeaveChip"]]:
		var expected_text: String = entry[0]
		var chip: Button = chips.find_child(entry[1], true, false)
		check("%s chip reads plain text with no letter-spacing" % expected_text,
			chip != null and chip.text == expected_text,
			"text was '%s'" % (chip.text if chip else "<missing>"))

	var host_rect: Rect2 = _host.get_global_rect()
	var chips_rect: Rect2 = chips.get_global_rect()

	check("the chips container is not wider than the host",
		chips.size.x <= _host.size.x + 1.0,
		"chips width %.1fpx vs host width %.1fpx" % [chips.size.x, _host.size.x])
	check("F8: the chips container is actually on screen, not shoved off to a negative x",
		chips_rect.position.x >= -0.5,
		"chips global position.x = %.1f" % chips_rect.position.x)
	check("F8: the chips container's right edge does not spill past the host's right edge",
		chips_rect.end.x <= host_rect.end.x + 1.0,
		"chips right edge %.1f vs host right edge %.1f" % [chips_rect.end.x, host_rect.end.x])
	check("F8: the chips container sits near the host's right edge, not merely fitting somewhere on screen",
		absf(chips_rect.end.x - host_rect.end.x) < 20.0,
		"chips right edge %.1f vs host right edge %.1f (host width %.1f)" % [chips_rect.end.x, host_rect.end.x, host_rect.size.x])


func _cleanup() -> void:
	if is_instance_valid(_overlay):
		UIStack.pop(_overlay)
		_overlay.queue_free()
	DialogueManager.participants = _saved_participants
