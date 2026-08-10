class_name AttributePrerequisite
extends PrerequisiteRule
## Requires one of the unit's core attributes to be at least min_value —
## e.g. "ST 12" as a prerequisite for a heavy weapon skill.

@export var attribute_name: String
@export var min_value: int


func is_satisfied(unit: Unit) -> bool:
	return unit.get_attribute_value(attribute_name) >= min_value
