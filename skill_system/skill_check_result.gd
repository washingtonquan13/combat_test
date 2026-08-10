class_name SkillCheckResult
extends RefCounted
## Small, stable value object returned by SkillCalculator.get_skill_level()
## — a computed roll target plus whether it's actually usable. Kept as a
## typed RefCounted rather than a Dictionary (unlike bigger, more
## heterogeneous result bags elsewhere in this project) since these two
## fields are always together and never grow — dot-notation access on a
## known shape reads better than dictionary keys for something this small.

var skill_level: int
var can_use_skill: bool


func _init(initial_skill_level: int = 0, initial_can_use_skill: bool = false) -> void:
	skill_level = initial_skill_level
	can_use_skill = initial_can_use_skill
