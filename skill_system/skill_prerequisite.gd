class_name SkillPrerequisite
extends PrerequisiteRule
## Requires another skill to be usable (trained or via a valid default)
## at least min_value — e.g. "Broadsword 12" as a prerequisite for a
## more advanced weapon skill. Routes through SkillCalculator, the same
## resolution a direct skill-level query would use, so a prerequisite
## check can never disagree with what SkillCalculator.get_skill_level
## would itself report for this unit and skill.

@export var skill_name: String
@export var min_value: int


func is_satisfied(unit: Unit) -> bool:
	var result: SkillCheckResult = SkillCalculator.get_skill_level(unit, skill_name)
	return result.can_use_skill and result.skill_level >= min_value
