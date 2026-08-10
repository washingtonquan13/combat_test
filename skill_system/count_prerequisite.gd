class_name CountPrerequisite
extends PrerequisiteRule
## N-of-M composite gate over its own subrules — the one general
## composition mechanism for this system. required_count = -1 means
## "all of subrules" (AND), = 1 means "any of subrules" (OR), or any
## specific N for "at least N of these M." Extends PrerequisiteRule like
## every leaf rule, so it nests inside itself (or any other rule's
## subrules array) arbitrarily deep — "all of (X and (any 2 of Y, Z,
## W))" is just a CountPrerequisite whose subrules contains another one.
## This is what replaced a separate AllOf/AnyOf pair of types that
## DIDN'T extend PrerequisiteRule and so could only ever appear at the
## very top of a prerequisite tree, never nested.

@export var required_count: int = -1
@export var subrules: Array[PrerequisiteRule] = []


func is_satisfied(unit: Unit) -> bool:
	var needed: int = subrules.size() if required_count < 0 else required_count
	var satisfied: int = 0
	for rule in subrules:
		if rule.is_satisfied(unit):
			satisfied += 1
			if satisfied >= needed:
				return true
	return satisfied >= needed
