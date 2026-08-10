class_name SkillInstance
extends Resource
## One unit's trained investment in a skill it actually knows — a Skill
## definition plus how many levels this specific unit has bought. A Node
## in the original design (reparented into a Character's $Skills child so
## SkillCalculator could find it via get_node("Skills").get_children()) —
## nothing here actually needs the scene tree, so this is a plain
## Resource instead, referenced directly from Unit.skills the same way
## Unit.abilities/custom_slots already reference Ability resources.

@export var skill_data: Skill = null
## Levels purchased beyond the base (1 = just the base attribute+
## difficulty roll, matching GURPS' point-buy progression) — NOT the
## final computed roll target. Named levels_purchased rather than
## skill_level specifically to not read as the same thing
## SkillCheckResult.skill_level means (that one IS the computed target).
@export var levels_purchased: int = 1


func get_relative_skill_level(attribute_value: int) -> int:
	return attribute_value + skill_data.difficulty_level + (levels_purchased - 1)
