class_name ChoiceRow
extends PanelContainer
## One discrete, focusable dialogue response row — replaces the old
## dialogue_overlay.gd's single RichTextLabel-with-[url=index] approach,
## where every choice was one line inside one shared clickable text blob.
##
## Root is a PanelContainer, not a Button. A Button's minimum size comes
## only from its OWN text/icon — a full-rect child inside one does not
## contribute to that minimum, so a row whose Text label wraps to two
## lines never grew and the second line clipped. PanelContainer is a real
## Container: its minimum size is derived from its child (Content, an
## HBoxContainer holding Index/Text/Tags), so a wrapped Text label's taller
## minimum size propagates up and the row actually grows. Click and
## keyboard-activate are handled by hand in _on_gui_input (a PanelContainer
## has no pressed signal the way Button does); hover and focus are tracked
## the same way (mouse_entered/exited, focus_entered/exited) and drive
## _refresh_style(), which swaps the single "panel" stylebox override —
## PanelContainer only has that one override slot, unlike Button's
## separate normal/hover/pressed/focus slots, so state has to be tracked
## here instead of left to the theme system.
##
## normal_style/hover_style/focus_style are @export StyleBox slots, backed
## by sub_resources baked into choice_row.tscn — editable in the inspector
## like any other themed Control, rather than three StyleBoxFlat objects
## built by hand in _ready(). Each of those three sub_resources has
## resource_local_to_scene = true, which is what still gives every
## INSTANCE of this scene its own independent copies despite them all
## being declared once in the same .tscn — Godot duplicates a
## local-to-scene resource per instantiate() call, so set_accent_color's
## per-instance border_color mutation below can never bleed into a
## different row the way one shared sub_resource would.
##
## focus_style is deliberately NOT identical to hover_style — it adds a
## thin border on all four sides (not just the left accent border) and a
## brighter background tint, so a keyboard-focused row still reads as
## focused even while the mouse happens to be resting over a different
## row (hover and focus are independent states here, and border_color
## alone can't tell them apart since set_accent_color sets it identically
## on both).
##
## disabled_alpha exposes the modulate.a a disabled row fades to, instead
## of a bare 0.4 literal in the setter below.
##
## normal/hover/focus styleboxes: transparent background at rest, a left
## border in the accent colour on hover OR keyboard focus, nothing on
## disabled (so a frozen row still reads as inert, not just unclickable).

## Carries the snapshot choice id (see Conversation.choose), not a position
## in a list, so a row can never fire a different choice than it shows.
signal chosen(id: StringName)

@export var normal_style: StyleBoxFlat
@export var hover_style: StyleBoxFlat
@export var focus_style: StyleBoxFlat
@export var disabled_alpha: float = 0.4

@onready var _index_label: Label = $Content/Index
@onready var _text_label: Label = $Content/Text
@onready var _tags_label: RichTextLabel = $Content/Tags

var _id: StringName = &""
var _hovering: bool = false

## External API, same contract the old Button-based row had:
## DialogueOverlay._set_choices_interactive sets this on every row while a
## skill-check roll plays out, rather than clearing the list — see that
## method's own comment. Disabling drops focus and stops the row from
## receiving mouse input at all (MOUSE_FILTER_IGNORE), rather than just
## ignoring clicks in _on_gui_input, so a disabled row also can't be
## Tab-focused or show a hover state.
var disabled: bool = false:
	set(value):
		disabled = value
		mouse_filter = Control.MOUSE_FILTER_IGNORE if value else Control.MOUSE_FILTER_STOP
		focus_mode = Control.FOCUS_NONE if value else Control.FOCUS_ALL
		modulate.a = disabled_alpha if value else 1.0
		_refresh_style()


func _ready() -> void:
	add_theme_stylebox_override("panel", normal_style)

	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	focus_entered.connect(_refresh_style)
	focus_exited.connect(_refresh_style)
	gui_input.connect(_on_gui_input)


func set_accent_color(color: Color) -> void:
	hover_style.border_color = color
	focus_style.border_color = color
	_refresh_style()


## entry is one snapshot choice (see Conversation.describe_choice): the
## stable choice id to hand back on chosen, the formatted text, and the
## display data for the tags — already computed by the conversation with
## the same code that rolls, so this row never touches SkillCalculator or
## the DialogueChoice resource itself. row_index only numbers the row.
func setup(row_index: int, entry: Dictionary) -> void:
	_id = entry.get("id", &"")
	disabled = false
	_index_label.text = "%02d" % (row_index + 1)
	_text_label.text = entry.get("text", "")
	_tags_label.text = " ".join(_build_tags(entry))


func _build_tags(entry: Dictionary) -> Array[String]:
	var tags: Array[String] = []

	var alignment_bb: String = DialogueFormat.alignment_tag(entry.get("alignment", ""))
	if alignment_bb != "":
		tags.append(alignment_bb)

	var check: Dictionary = entry.get("check", {})
	if not check.is_empty():
		if check.get("hidden", false):
			# A neutral marker rather than collapsing the whole row to
			# "???" (DialogueFormat.choice_label's behaviour) — the response
			# text itself still reads normally; only the skill preview is
			# withheld, same as BG3 not revealing a passive check's DC.
			tags.append("[color=#808080]?[/color]")
		else:
			var skill: String = check.get("skill", "")
			var target: int = check.get("target", 0)
			if check.get("can_use", false):
				tags.append("[color=#%s]|%s %d|[/color]" % [
					DialogueFormat.skill_tag_color.to_html(false), skill, target])
			elif check.get("attemptable", false):
				# The one requested deviation from the mockup: still the
				# real number, just styled untrained (muted grey) instead
				# of the word "untrained".
				tags.append("[color=#909090]|%s %d|[/color]" % [skill, target])
			# can_use == false and attemptable == false: nothing to
			# preview at all, no tag shown.
			var assistant: String = check.get("assistant", "")
			if assistant != "":
				tags.append("[color=#CFCFCF](%s)[/color]" % assistant)

	for cost in entry.get("costs", PackedStringArray()):
		tags.append("[color=#D4AF37]%s[/color]" % cost)

	return tags


func _on_mouse_entered() -> void:
	_hovering = true
	_refresh_style()


func _on_mouse_exited() -> void:
	_hovering = false
	_refresh_style()


func _on_gui_input(event: InputEvent) -> void:
	if disabled:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		accept_event()
		chosen.emit(_id)
	elif event.is_action_pressed("ui_accept"):
		accept_event()
		chosen.emit(_id)


func _refresh_style() -> void:
	# Guarded: the `disabled` setter can fire from the default-value
	# assignment at object construction, before _ready() has run — the
	# exported styles are assigned by the .tscn before _ready(), but
	# _ready() itself hasn't connected anything yet at that point either,
	# so this stays a defensive null check rather than a dead one.
	if normal_style == null:
		return
	if disabled:
		add_theme_stylebox_override("panel", normal_style)
		return
	if has_focus() or _hovering:
		add_theme_stylebox_override("panel", focus_style if has_focus() else hover_style)
	else:
		add_theme_stylebox_override("panel", normal_style)
