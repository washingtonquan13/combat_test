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

signal chosen(index: int)

@export var normal_style: StyleBoxFlat
@export var hover_style: StyleBoxFlat
@export var focus_style: StyleBoxFlat
@export var disabled_alpha: float = 0.4

@onready var _index_label: Label = $Content/Index
@onready var _text_label: Label = $Content/Text
@onready var _tags_label: RichTextLabel = $Content/Tags

var _index: int = -1
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


## row_index is the position in DialogueManager's own FILTERED choices
## list (what choices_shown emitted) — stored as-is and handed straight
## back on chosen, never remapped. See dialogue_manager.gd's own comment
## on _visible_choices for why a lookup here would be a real, previously-
## shipped bug.
##
## Guards both new-format APIs (DialogueFormat.skill_parts,
## DialogueChoice.cost_tags) with has_method()/call() on real INSTANCES
## rather than calling them directly — a direct `DialogueFormat.skill_parts(...)`
## would be a compile-time error the instant that static method doesn't
## exist yet, which has_method()/call() on an Object instance never is.
## Falls back to the old single-string DialogueFormat.choice_label() (the
## alignment/skill-preview/"???"-collapse formatting the previous overlay
## build already used) if either API isn't there yet.
func setup(row_index: int, choice: DialogueChoice) -> void:
	_index = row_index
	disabled = false
	_index_label.text = "%02d" % (row_index + 1)

	var format_probe: RefCounted = DialogueFormat.new()
	var has_skill_parts: bool = format_probe.has_method("skill_parts")
	var has_cost_tags: bool = choice.has_method("cost_tags")

	if not has_skill_parts or not has_cost_tags:
		# choice_label() returns a BBCode-formatted string (alignment/skill
		# tags baked in as [color=...] fragments) meant for the old
		# RichTextLabel-based Text — Text is a plain Label now (see F2/F16),
		# which would render those brackets as literal characters instead
		# of parsing them. This fallback only exists for version skew
		# between this file and DialogueFormat/DialogueChoice (see the doc
		# comment above); as of this rebuild both guarded methods already
		# exist, so choice.text alone (no tag preview, same as a hidden
		# check collapsing to plain text) is the safe degrade — a missing
		# preview reads as incomplete, not as a rendering bug.
		_text_label.text = choice.text
		_tags_label.text = ""
		return

	_text_label.text = choice.text
	_tags_label.text = " ".join(_build_tags(format_probe, choice))


func _build_tags(format_probe: RefCounted, choice: DialogueChoice) -> Array[String]:
	var tags: Array[String] = []

	# Pre-existing API (not one of the two guarded ones above) — safe to
	# call directly.
	var alignment_bb: String = DialogueFormat.alignment_tag(choice.alignment_name)
	if alignment_bb != "":
		tags.append(alignment_bb)

	var parts: Dictionary = format_probe.call("skill_parts", choice)
	if not parts.is_empty():
		if parts.get("hidden", false):
			# A neutral marker rather than collapsing the whole row to
			# "???" (the old choice_label behaviour) — the response text
			# itself still reads normally; only the skill preview is
			# withheld, same as BG3 not revealing a passive check's DC.
			tags.append("[color=#808080]?[/color]")
		else:
			var skill: String = parts.get("skill", "")
			if skill != "":
				var target: int = parts.get("target", 0)
				var can_use: bool = parts.get("can_use", false)
				var attemptable: bool = parts.get("attemptable", false)
				if can_use:
					tags.append("[color=#%s]|%s %d|[/color]" % [
						DialogueFormat.skill_tag_color.to_html(false), skill, target])
				elif attemptable:
					# The one requested deviation from the mockup: still
					# the real number, just styled untrained (muted grey)
					# instead of the word "untrained".
					tags.append("[color=#909090]|%s %d|[/color]" % [skill, target])
				# can_use == false and attemptable == false: nothing to
				# preview at all, no tag shown.
				var assistant: String = parts.get("assistant", "")
				if assistant != "":
					tags.append("[color=#CFCFCF](%s)[/color]" % assistant)

	var cost_list: PackedStringArray = choice.call("cost_tags")
	for cost in cost_list:
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
		chosen.emit(_index)
	elif event.is_action_pressed("ui_accept"):
		accept_event()
		chosen.emit(_index)


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
