class_name SkillBonusBehavior
extends StatusBehavior
## A bonus to a chosen set of skills.

@export var skills: Array[Skill] = []
@export var amount: int = 1


func at_level(level: int) -> StatusBehavior:
	if level == 1:
		return self
	var scaled: SkillBonusBehavior = duplicate()
	scaled.amount = amount * level
	return scaled


func skill_bonus(skill: Skill) -> int:
	return amount if skills.has(skill) else 0


func describe() -> String:
	var names: PackedStringArray = []
	for skill in skills:
		names.append(skill.skill_name)
	return "%+d to %s" % [amount, ", ".join(names)]
