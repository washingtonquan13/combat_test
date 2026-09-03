extends UIScreen
## Lower-third dialogue band — replaces the old full-width 35%-of-screen
## slab (anchor_top = 0.65 to bottom, a flat 55%-alpha PanelContainer)
## with a band that sits low, insets from both edges, and sizes itself to
## its own CONTENT instead of a fixed fraction of the viewport. The world
## stays visible above and around it; a soft upward gradient scrim, now
## PART of Band's own panel style (see BAND/SCRIM below), is what keeps
## text legible, not a hard panel edge.
##
## SIZING: no layout lives in this script at all — every size relationship
## is anchors/size-flags baked into dialogue_overlay.tscn, editable in the
## Godot inspector. Stack (a full-height VBoxContainer, anchor_left/right
## at 6.5%/93.5%, anchor_top 0 / anchor_bottom 1) is the inset column;
## alignment = END is what bottom-aligns its one child (BandMargin) without
## any negative-offset/zero-height-sliver trick a 2D-editor drag could ever
## grab. BandMargin carries only the 29px bottom gap
## (theme_override_constants/margin_bottom); Band (see below) sits inside
## it and hugs its own children's combined minimum size, growing UPWARD as
## more choice rows appear or the speaker/aside text wraps to more lines —
## no spacer trick, no per-frame resize code. The horizontal extent comes
## from Stack's two side anchors alone, so it holds at any resolution
## instead of the old fixed 104px MarginContainer inset.
##
## BAND/SCRIM: Band is a PanelContainer, not a plain VBoxContainer — its
## `panel` stylebox is a StyleBoxTexture wrapping the same GradientTexture2D
## the old standalone Scrim TextureRect used, with expand_margin_top/left/
## right/bottom pushing the painted area out past Band's own rect: up and
## to both sides far enough to clear the 6.5%/93.5% inset at any tested
## resolution, and down through BandMargin's 29px gap to the screen edge.
## A StyleBoxTexture's expand margins are pure paint — draw calls in Godot
## aren't clipped by an ancestor's rect unless that ancestor sets
## clip_contents, and nothing in this chain does — so the gradient always
## covers exactly "the band plus a soft area above it," however tall Band
## grows, with no separate node to keep in sync. BandContent (a plain
## VBoxContainer) holds the actual Aside/Speaker/Line/Choices/Continue
## stack inside Band; the StyleBoxTexture's content_margin_top/bottom give
## the band its own internal padding independent of BandMargin's outer gap.
##
## MOUSE-FILTER: every node that exists only to POSITION or PAINT the band
## — this root, Stack, BandMargin, and Band itself (even though it now
## paints the gradient) — is MOUSE_FILTER_IGNORE, so a click anywhere
## those nodes' rects cover but no interactive control does falls through
## to whatever's underneath: the 3D world, unit selection, or (now that
## PartyRail sits earlier in the same CanvasLayer, see main_root.tscn) the
## party portraits. Only actual interactive leaves — each ChoiceRow, the
## Continue button, and the four chips — keep Godot's default STOP, which
## is what lets THEM capture clicks/hover; Chips itself (an HBoxContainer
## that only positions its four children) is IGNORE for the same reason.
## BandContent and the plain Aside/Speaker/Line/Choices layout nodes are
## IGNORE too — they're layout, not interaction. See ChoiceRow for how a
## row itself captures.
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

## Fallback when no "player" participant has resolved yet (should not
## happen mid-conversation, but _accent_color() has to return SOMETHING
## before the first line_shown/choices_shown lands).
const DEFAULT_ACCENT_COLOR: Color = Color(0.85, 0.7, 0.32)

const ChoiceRowScene: PackedScene = preload("res://systems/dialogue_system/choice_row.tscn")

@onready var _band: Control = $Stack/BandMargin/Band
@onready var _aside_label: Label = $Stack/BandMargin/Band/BandContent/Aside
@onready var _speaker_name_label: Label = $Stack/BandMargin/Band/BandContent/Speaker
@onready var _line_label: Label = $Stack/BandMargin/Band/BandContent/Line
@onready var _choice_list: VBoxContainer = $Stack/BandMargin/Band/BandContent/Choices
@onready var _continue_button: Button = $Stack/BandMargin/Band/BandContent/Continue
@onready var _log_chip: Button = $Chips/LogChip
@onready var _history_chip: Button = $Chips/HistoryChip
@onready var _settings_chip: Button = $Chips/SettingsChip
@onready var _leave_chip: Button = $Chips/LeaveChip

var _choice_rows: Array[ChoiceRow] = []


func _ready() -> void:
	visible = false

	_continue_button.pressed.connect(_on_continue_pressed)
	_log_chip.pressed.connect(_on_log_pressed)
	_history_chip.pressed.connect(_on_stub_pressed.bind("History"))
	_settings_chip.pressed.connect(_on_stub_pressed.bind("Settings"))
	_leave_chip.pressed.connect(_on_stub_pressed.bind("Leave"))
	# History/Settings/Leave are marked as stubs visually (dimmed + a
	# tooltip), not just functionally — a chip that looks
	# exactly like Log but silently does nothing on press would read as
	# broken rather than "not built yet." That marking (tooltip_text +
	# modulate) is now baked into dialogue_overlay.tscn directly on those
	# three chips, not set here, so it's visible/editable in the inspector
	# instead of only discoverable by reading this script.

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
## speaker's name only updates when a real token is given, so consecutive
## lines from the SAME speaker leave the name alone (nothing here
## re-triggers on an unchanged token — there is no per-line enter
## animation to restart in the first place).
func _on_line_shown(text: String, speaker_token: String) -> void:
	if speaker_token == "":
		_aside_label.text = text
		return

	var unit: Unit = DialogueManager.participants.get(speaker_token)
	var speaker_name: String = unit.get_display_name() if unit else speaker_token.capitalize()
	_speaker_name_label.text = speaker_name.to_upper()
	# Overridden here every line, not left to a static .tscn value: the
	# real source of truth is the PLAYER unit's own selected_color (see
	# _accent_color below), which isn't known until a conversation is
	# actually running. dialogue_overlay.tscn's Speaker node deliberately
	# carries no font_color override of its own — one here would be dead
	# the instant the first line renders, and worse, would silently read
	# as "the" colour to anyone editing the .tscn.
	_speaker_name_label.add_theme_color_override("font_color", _accent_color())
	_line_label.text = text


func _on_choices_shown(choices: Array[DialogueChoice]) -> void:
	_clear_choice_rows()

	if choices.is_empty():
		_continue_button.visible = true
		_continue_button.disabled = false
		_continue_button.text = "End Conversation" if DialogueManager.current_node.next_node_id == "" else "Continue"
		_continue_button.grab_focus()
		return

	_continue_button.visible = false
	var accent: Color = _accent_color()
	for i in choices.size():
		var row: ChoiceRow = ChoiceRowScene.instantiate()
		# Width comes from choice_row.tscn's own size_flags_horizontal = 3
		# (EXPAND_FILL) on the row root, not set here — uniform width
		# across the list (rather than each row hugging its own content)
		# is what keeps the right-aligned tags lined up down the column.
		_choice_list.add_child(row)
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

	# First row grabs keyboard focus so a keyboard-only user has something
	# focused the instant the list appears, rather than needing an initial
	# Tab press just to discover the list is navigable at all.
	_choice_rows[0].grab_focus()


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
