extends UIScreen
## Lower-third dialogue band — replaces the old full-width 35%-of-screen
## slab (anchor_top = 0.65 to bottom, a flat 55%-alpha PanelContainer)
## with a band that sits low, insets from both edges, and sizes itself to
## its own CONTENT instead of a fixed fraction of the viewport. The world
## stays visible above and around it; a soft upward gradient scrim (see
## Scrim below) is what keeps text legible, not a hard panel edge.
##
## SIZING TRICK: Layout is a full-rect VBoxContainer with an EXPAND_FILL
## spacer above Band and nothing below it — the exact same "pin to the
## bottom of a VBoxContainer via an expanding sibling" technique the OLD
## build already used (there: an expanding PanelContainer under a fixed
## anchor_top = 0.65 cutoff). Here Band itself is left at its default,
## non-expanding size flag, so it takes exactly its own minimum size
## (portrait + text + however many choice rows are showing) and the
## spacer eats everything above it. No anchor math, no per-frame resize
## code — Godot's own Container minimum-size layout does the sizing.
##
## MOUSE-FILTER: the root and every full-screen wrapper around Band
## (Layout, the expanding spacer, Scrim) are explicitly
## MOUSE_FILTER_IGNORE, so a click anywhere the band ISN'T visually
## occupying falls through to the 3D world/unit-selection below — the old
## root defaulted to Godot's STOP and silently ate every click across the
## whole bottom 35% of the screen, band content or not. Band itself and
## everything inside it (choice rows, chips, the Continue button) stay at
## the ordinary default (STOP), which is exactly what lets THEM capture
## clicks/hover — see ChoiceRow.
##
## Response options are one ChoiceRow (see choice_row.gd/.tscn) per
## choice rather than the old single-RichTextLabel-with-[url] approach —
## a discrete focusable row per choice is what lets hover AND keyboard
## focus both drive the same left-border highlight, and lets a row be
## individually disabled (see _set_choices_interactive) without having to
## re-render or clear the whole list.
##
## hides_hud/blocks_input_below/closes_on_cancel are authored on this
## scene's instance in MainRoot.tscn (owned by another agent) — see
## UIScreen's own header.

## 1600x900 mockup baseline: 58px square portrait, ~560px text column
## (approximates the "wrap at ~62 characters" spec for the body font),
## 70px choice indent (portrait width + the row's own spacing), 104px/29px
## side/bottom band insets (1600*0.065, 900*0.032). Fixed pixel constants
## rather than percentages, matching how the rest of this project's
## hand-authored UI is already sized (see skill_check_dice_popup.gd's own
## _CORNER_SIZE/_CORNER_MARGIN) — a percentage-of-viewport MarginContainer
## isn't something Godot's container margins express directly anyway.
const BAND_SIDE_INSET: int = 104
const BAND_BOTTOM_INSET: int = 29
const TEXT_COLUMN_WIDTH: float = 560.0
const CHOICE_INDENT: int = 70

## Fallback when no "player" participant has resolved yet (should not
## happen mid-conversation, but _accent_color() has to return SOMETHING
## before the first line_shown/choices_shown lands).
const DEFAULT_ACCENT_COLOR: Color = Color(0.85, 0.7, 0.32)

const STUB_TOOLTIP: String = "Not implemented yet."

const ChoiceRowScene: PackedScene = preload("res://systems/dialogue_system/choice_row.tscn")

@onready var _band: Control = $Layout/Band
@onready var _aside_label: Label = $Layout/Band/Content/AsideLabel
@onready var _portrait: TextureRect = $Layout/Band/Content/MainRow/Portrait
@onready var _speaker_name_label: Label = $Layout/Band/Content/MainRow/TextColumn/SpeakerNameLabel
@onready var _line_label: Label = $Layout/Band/Content/MainRow/TextColumn/LineLabel
@onready var _choice_list: VBoxContainer = $Layout/Band/Content/ChoiceArea/ChoiceStack/ChoiceList
@onready var _continue_button: Button = $Layout/Band/Content/ChoiceArea/ChoiceStack/ContinueButton
@onready var _log_chip: Button = $TopRightChips/LogChip
@onready var _history_chip: Button = $TopRightChips/HistoryChip
@onready var _settings_chip: Button = $TopRightChips/SettingsChip
@onready var _leave_chip: Button = $TopRightChips/LeaveChip

var _choice_rows: Array[ChoiceRow] = []


func _ready() -> void:
	visible = false

	_continue_button.pressed.connect(_on_continue_pressed)
	_log_chip.pressed.connect(_on_log_pressed)
	_history_chip.pressed.connect(_on_stub_pressed.bind("History"))
	_settings_chip.pressed.connect(_on_stub_pressed.bind("Settings"))
	_leave_chip.pressed.connect(_on_stub_pressed.bind("Leave"))
	# Marked as stubs visually (dimmed + a tooltip), not just functionally —
	# a chip that looks exactly like Log but silently does nothing on
	# press would read as broken rather than "not built yet."
	for chip in [_history_chip, _settings_chip, _leave_chip]:
		chip.tooltip_text = STUB_TOOLTIP
		chip.modulate = Color(1.0, 1.0, 1.0, 0.5)

	DialogueManager.dialogue_started.connect(_on_dialogue_started)
	DialogueManager.line_shown.connect(_on_line_shown)
	DialogueManager.choices_shown.connect(_on_choices_shown)
	DialogueManager.dialogue_ended.connect(_on_dialogue_ended)
	DialogueManager.dice_roll_requested.connect(_on_dice_roll_requested)


func _on_dialogue_started(_root: DialogueNode) -> void:
	open()
	_clear_choice_rows()
	_continue_button.visible = false
	_aside_label.text = ""


## speaker_token == "" is a system echo (alignment shift, roll result, who
## assisted) — goes to the dimmed aside line above the row, never the
## speaker row itself, same distinction the old build made. A real
## speaker's name/portrait only update when a real token is given, so
## consecutive lines from the SAME speaker leave the name/portrait alone
## (nothing here re-triggers on an unchanged token — there is no per-line
## enter animation to restart in the first place).
func _on_line_shown(text: String, speaker_token: String) -> void:
	if speaker_token == "":
		_aside_label.text = text
		return

	var unit: Unit = DialogueManager.participants.get(speaker_token)
	var speaker_name: String = unit.get_display_name() if unit else speaker_token.capitalize()
	_speaker_name_label.text = _spaced_upper(speaker_name)
	_speaker_name_label.add_theme_color_override("font_color", _accent_color())
	_portrait.texture = unit.portrait_texture if unit else null
	_line_label.text = text


func _on_choices_shown(choices: Array[DialogueChoice]) -> void:
	_clear_choice_rows()

	if choices.is_empty():
		_continue_button.visible = true
		_continue_button.disabled = false
		_continue_button.text = "End Conversation" if DialogueManager.current_node.next_node_id == "" else "Continue"
		return

	_continue_button.visible = false
	var accent: Color = _accent_color()
	for i in choices.size():
		var row: ChoiceRow = ChoiceRowScene.instantiate()
		_choice_list.add_child(row)
		# Uniform width across every row in the list (rather than each
		# hugging its own content) so the right-aligned tags actually line
		# up down the column instead of drifting per-row.
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.set_accent_color(accent)
		# i is the position in the FILTERED list DialogueManager just
		# emitted — passed straight through to DialogueManager.choose()
		# unchanged. choose() indexes THIS list, not the node's raw
		# choices array (see dialogue_manager.gd's own load-bearing
		# comment on _visible_choices) — a lookup or remap here would
		# silently reintroduce the exact bug that comment describes.
		row.setup(i, choices[i])
		row.chosen.connect(_on_choice_chosen)
		_choice_rows.append(row)


## The choice that was just picked is already committed on the manager
## side; what's still on screen here is the OLD choice list/Continue
## button, left visible but frozen for as long as the roll takes to play
## out under skill_check_dice_popup.gd. Disabling every row (rather than
## clearing them, the old build's approach) is what keeps a second click
## from firing DialogueManager.choose() again into a resolution that's
## still awaiting dice_roll_finished. Nothing restores these — the
## resolution already running emits a fresh choices_shown/line_shown once
## it actually finishes, same as any other node transition.
func _on_dice_roll_requested(_skill_name: String, _roll: Dictionary) -> void:
	_set_choices_interactive(false)


func _on_dialogue_ended() -> void:
	close()
	var log: UIScreen = get_tree().get_first_node_in_group("conversation_log")
	if log:
		UIStack.pop(log)


func _on_choice_chosen(index: int) -> void:
	DialogueManager.choose(index)


func _on_continue_pressed() -> void:
	DialogueManager.advance()


func _on_log_pressed() -> void:
	var log: UIScreen = get_tree().get_first_node_in_group("conversation_log")
	if not log:
		return
	if UIStack.is_open(log):
		UIStack.pop(log)
	else:
		UIStack.push(log)


func _on_stub_pressed(chip_name: String) -> void:
	push_warning("DialogueOverlay: '%s' chip is not implemented yet." % chip_name)


func _set_choices_interactive(value: bool) -> void:
	for row in _choice_rows:
		if is_instance_valid(row):
			row.disabled = not value
	_continue_button.disabled = not value


func _clear_choice_rows() -> void:
	for row in _choice_rows:
		if is_instance_valid(row):
			row.queue_free()
	_choice_rows.clear()


## The "player accent colour" the mockup calls for is the real player
## unit's own selected_color — the same per-unit accent unit_portrait.gd
## already draws as a selection outline, rather than a second hardcoded
## palette entry this file would own on its own. Falls back to a neutral
## gold before any participant has resolved.
func _accent_color() -> Color:
	var player: Unit = DialogueManager.participants.get("player")
	return player.selected_color if player else DEFAULT_ACCENT_COLOR


## Poor-man's letter-spacing: Label has no letter-spacing theme property
## in this project (no FontVariation/monospace font asset exists here to
## build one from — checked), so this fakes the "small, letter-spaced,
## uppercase" look by joining characters with a thin space instead of
## depending on an unverified font resource that could just as easily
## render blank. Used for the speaker name and, from choice_row.gd, is
## NOT needed there (index/tags use plain BBCode color, no spacing call).
static func _spaced_upper(text: String) -> String:
	var upper: String = text.to_upper()
	var glyphs: PackedStringArray = []
	for i in upper.length():
		glyphs.append(upper[i])
	return " ".join(glyphs)
