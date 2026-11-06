@tool
class_name AttributePrerequisite
extends PrerequisiteRule
## Requires one of the unit's core attributes to be at least min_value —
## e.g. "ST 12" as a prerequisite for a heavy weapon skill. Any stat id
## works (the Inspector suggests them); @tool only for that suggestion.

@export var attribute_name: StringName
@export var min_value: int


func _validate_property(property: Dictionary) -> void:
	if property.name == "attribute_name":
		StatDatabase.suggest_ids(property)


func is_satisfied(unit: Unit) -> bool:
	return unit.get_attribute_value(attribute_name) >= min_value
