@tool
extends EditorProperty
## Inspector editor for any String property that holds an AnimationPlayer
## clip name (see animation_clip_inspector_plugin.gd for the exact match
## rule) — an OptionButton populated from every clip the shared rig can
## actually play, so a typo can't be entered and the dropdown IS the
## authoritative list unit_animator.gd's has_animation() checks accept.

const RigUtils := preload("res://addons/animation_sequence_tools/rig_utils.gd")

var _option_button: OptionButton = OptionButton.new()
var _item_values: PackedStringArray = PackedStringArray()  # parallel to _option_button's items — item i's REAL value, independent of its displayed label
var _name_to_index: Dictionary = {}  # animation name -> item index, for the common (recognized) case
var _unknown_item_index: int = -1    # index of the synthetic "value not in list" item, or -1 if none is currently shown
var _updating: bool = false          # guards _on_item_selected while _update_property() is driving the control itself


func _init() -> void:
	_option_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_option_button)
	add_focusable(_option_button)
	set_bottom_editor(_option_button)
	_add_item("(none)", "")
	for clip_name in RigUtils.get_all_clip_names():
		_add_item(clip_name, clip_name)
	_option_button.item_selected.connect(_on_item_selected)


func _add_item(label: String, value: String) -> void:
	_option_button.add_item(label)
	_item_values.append(value)
	_name_to_index[value] = _item_values.size() - 1


func _update_property() -> void:
	var current_value: String = get_edited_object().get(get_edited_property())
	_updating = true

	# Drop last call's synthetic "unrecognized" entry, if any — always the
	# LAST item, so removing it never shifts any real item's index.
	if _unknown_item_index != -1:
		_option_button.remove_item(_unknown_item_index)
		_item_values.remove_at(_unknown_item_index)
		_unknown_item_index = -1

	if _name_to_index.has(current_value):
		_option_button.select(_name_to_index[current_value])
	else:
		# Nonempty and not on the rig — a typo, stale data, or a name from
		# some future second rig. Surface it verbatim instead of silently
		# snapping to "(none)" or whatever sits at index 0 — either would
		# quietly rewrite this field's real data the instant the user
		# touched anything else in the Inspector.
		_option_button.add_item("%s (not found)" % current_value)
		_unknown_item_index = _option_button.get_item_count() - 1
		_item_values.append(current_value)
		_option_button.select(_unknown_item_index)

	_updating = false


func _on_item_selected(index: int) -> void:
	if _updating:
		return
	emit_changed(get_edited_property(), _item_values[index])
