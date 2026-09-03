class_name ChoiceRow
extends Button
## One discrete, focusable dialogue response row — replaces the old
## dialogue_overlay.gd's single RichTextLabel-with-[url=index] approach,
## where every choice was one line inside one shared clickable text blob.
## A Button per row gets hover AND keyboard focus for free from Godot
## (Tab cycles rows, Space/Enter activates the focused one), and lets
## exactly one row be disabled without touching its siblings — see
## DialogueOverlay._set_choices_interactive, which freezes the whole list
## non-interactively while a skill-check roll plays out rather than
## clearing it.
##
## Content is built in code, not baked into the .tscn, for two reasons:
## the left-border accent colour is per-conversation (the player unit's
## own selected_color, resolved at runtime — see set_accent_color), and
## the row needs independent StyleBoxFlat resources per INSTANCE, not one
## shared sub_resource every row would otherwise mutate together.
##
## flat = true suppresses Godot's default button chrome; the normal/
## hover/pressed/focus/disabled styleboxes built in _ready() replace it
## with exactly the look this row needs: transparent background at rest,
## a left border in the accent colour on hover OR keyboard focus, nothing
## on disabled (so a frozen row still reads as inert, not just unclickable).

signal chosen(index: int)

## Neutral border colour before setup()/set_accent_color() ever runs —
## matches dialogue_overlay.gd's own DEFAULT_ACCENT_COLOR fallback
## constant (duplicated rather than shared: that constant lives on a
## UIScreen subclass, not somewhere a plain Button widget should reach
## into).
const DEFAULT_ACCENT_COLOR: Color = Color(0.85, 0.7, 0.32)

@onready var _index_label: Label = $Content/IndexLabel
@onready var _text_label: RichTextLabel = $Content/TextLabel
@onready var _tags_label: RichTextLabel = $Content/TagsLabel

var _index: int = -1
var _normal_style: StyleBoxFlat
var _hover_style: StyleBoxFlat
var _focus_style: StyleBoxFlat


func _ready() -> void:
	flat = true
	focus_mode = Control.FOCUS_ALL
	toggle_mode = false
	text = ""
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	_normal_style = StyleBoxFlat.new()
	_normal_style.bg_color = Color(0, 0, 0, 0)
	_normal_style.content_margin_left = 8.0
	_normal_style.content_margin_right = 8.0
	_normal_style.content_margin_top = 3.0
	_normal_style.content_margin_bottom = 3.0

	_hover_style = _normal_style.duplicate()
	_hover_style.bg_color = Color(1, 1, 1, 0.06)
	_hover_style.border_width_left = 3
	_hover_style.border_color = DEFAULT_ACCENT_COLOR

	_focus_style = _hover_style.duplicate()

	add_theme_stylebox_override("normal", _normal_style)
	add_theme_stylebox_override("hover", _hover_style)
	add_theme_stylebox_override("pressed", _hover_style)
	add_theme_stylebox_override("focus", _focus_style)
	add_theme_stylebox_override("disabled", _normal_style)

	pressed.connect(_on_pressed)


func set_accent_color(color: Color) -> void:
	_hover_style.border_color = color
	_focus_style.border_color = color


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
		_text_label.text = DialogueFormat.choice_label(choice)
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


func _on_pressed() -> void:
	chosen.emit(_index)
