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

## Fallback when no "player" is in the cast (should not happen
## mid-conversation, but _accent_color() has to return SOMETHING).
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
## The conversation this band is showing, or null. Held only between
## Conversations.began and its end.
var _conversation: Conversation = null
## How many transcript entries have already been drawn — the band reads
## only the new ones on each `changed`.
var _seen: int = 0
## The visit whose choices are on screen. Rows are rebuilt only when the
## conversation shows a node again, never on every `changed`, so keyboard
## focus survives an aside landing mid-choice.
var _shown_visit: int = -1
## The id the Continue button chooses: &"continue" or &"end".
var _builtin_id: StringName = &""


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

	# A band created while a conversation is already running (a scene
	# reload, a test) picks it up rather than waiting for the next one.
	Conversations.follow(self, _on_conversation_began)


func _exit_tree() -> void:
	_release()


## Only an ordinary dialogue is shown here; a negotiation has its own panel
## (see negotiation_panel.gd), and both decide that from the conversation's
## presentation hint, never from which manager started it.
func _on_conversation_began(c: Conversation) -> void:
	if c.presentation != &"dialogue":
		return
	_release()
	_conversation = c
	_seen = 0
	_shown_visit = -1
	_clear_choice_rows()
	_continue_button.visible = false
	_aside_label.text = ""
	c.changed.connect(_on_changed)
	open()
	_on_changed()


func _on_changed() -> void:
	var c: Conversation = _conversation
	if c == null:
		return
	if c.ended:
		_on_conversation_ended()
		return

	while _seen < c.transcript.size():
		_draw_entry(c.transcript[_seen])
		_seen += 1

	var snap: Dictionary = c.snapshot()
	if snap.visit != _shown_visit:
		_shown_visit = snap.visit
		_show_choices(snap.choices)
	# Frozen, not cleared, while a choice resolves or the dice play out
	# under skill_check_dice_popup.gd — a second click can't pick again
	# (Conversation.choose refuses it anyway), and nothing has to restore
	# the rows: the next node's `changed` rebuilds them.
	_set_choices_interactive(not snap.busy and snap.waiting.is_empty())


## An aside (speaker "" — an alignment note, a roll result, who assisted)
## goes to the dimmed line above the rows, never the speaker row itself.
## Plain text: the transcript carries no BBCode, and this is a Label, so
## the "(Lawful)" in an alignment note reads as written instead of showing
## raw color tags. A real speaker's name only updates on a real line, so
## consecutive lines from the SAME speaker leave the name alone.
func _draw_entry(entry: Dictionary) -> void:
	if entry.kind != &"line":
		_aside_label.text = entry.text
		return

	var speaker_name: String = entry.name if entry.name != "" else String(entry.speaker).capitalize()
	_speaker_name_label.text = speaker_name.to_upper()
	# Overridden here every line, not left to a static .tscn value: the
	# real source of truth is the PLAYER unit's own selected_color (see
	# _accent_color below), which isn't known until a conversation is
	# actually running. dialogue_overlay.tscn's Speaker node deliberately
	# carries no font_color override of its own — one here would be dead
	# the instant the first line renders, and worse, would silently read
	# as "the" colour to anyone editing the .tscn.
	_speaker_name_label.add_theme_color_override("font_color", _accent_color())
	_line_label.text = entry.text


func _show_choices(entries: Array) -> void:
	_clear_choice_rows()
	_builtin_id = &""

	var authored: Array[Dictionary] = []
	for entry in entries:
		if entry.get("builtin", false):
			_builtin_id = entry.id
		else:
			authored.append(entry)

	if authored.is_empty():
		_continue_button.visible = _builtin_id != &""
		if _builtin_id != &"":
			_continue_button.disabled = false
			_continue_button.text = entries[entries.size() - 1].text
			_continue_button.grab_focus()
		return

	_continue_button.visible = false
	var accent: Color = _accent_color()
	for i in authored.size():
		var row: ChoiceRow = ChoiceRowScene.instantiate()
		# Width comes from choice_row.tscn's own size_flags_horizontal = 3
		# (EXPAND_FILL) on the row root, not set here — uniform width
		# across the list (rather than each row hugging its own content)
		# is what keeps the right-aligned tags lined up down the column.
		_choice_list.add_child(row)
		row.set_accent_color(accent)
		# The row carries the choice's stable id, not its position here —
		# a position in a filtered list is exactly what used to fire the
		# wrong choice once an earlier one had been hidden on a revisit.
		row.setup(i, authored[i])
		row.chosen.connect(_on_choice_chosen)
		_choice_rows.append(row)

	# First row grabs keyboard focus so a keyboard-only user has something
	# focused the instant the list appears, rather than needing an initial
	# Tab press just to discover the list is navigable at all.
	_choice_rows[0].grab_focus()


func _on_conversation_ended() -> void:
	_release()
	close()
	var log: UIScreen = get_tree().get_first_node_in_group("conversation_log")
	if log:
		UIStack.pop(log)


func _release() -> void:
	if _conversation and _conversation.changed.is_connected(_on_changed):
		_conversation.changed.disconnect(_on_changed)
	_conversation = null


func _on_choice_chosen(id: StringName) -> void:
	if _conversation:
		_conversation.choose(id)


func _on_continue_pressed() -> void:
	if _conversation and _builtin_id != &"":
		_conversation.choose(_builtin_id)


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
## gold before any cast has resolved.
func _accent_color() -> Color:
	var player: Unit = _conversation.cast.get("player") as Unit if _conversation else null
	return player.selected_color if is_instance_valid(player) else DEFAULT_ACCENT_COLOR
