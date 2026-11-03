@tool
extends EditorInspectorPlugin
## BodyRow's three per-type arrays become one editable grid; a BodyPlan,
## an InjuryPreset and a UnitDefinition get a read-only table of what
## each location takes once the preset is applied.

const InjuryGrid := preload("res://addons/injury_inspector/injury_grid.gd")


func _can_handle(object: Object) -> bool:
	return object is BodyRow or object is BodyPlan or object is InjuryPreset or object is UnitDefinition


func _parse_begin(object: Object) -> void:
	if object is BodyPlan or object is InjuryPreset:
		add_custom_control(_effective(object))


func _parse_property(object: Object, _type: Variant.Type, name: String, _hint: PropertyHint, _hint_string: String, _usage: int, _wide: bool) -> bool:
	if object is BodyRow:
		if name == "multipliers":
			var grid := InjuryGrid.new()
			grid.edit_row(object)
			add_custom_control(grid)
			return true
		return name == "max_injury" or name == "dr"
	# Right under the fields that decide it.
	if object is UnitDefinition and name == "ai_archetype":
		add_custom_control(_effective(object))
	return false


func _effective(object: Object) -> Control:
	var grid := InjuryGrid.new()
	grid.show_effective(object)
	return grid
