class_name SkillInstance
extends Node
## One unit's trained investment in a skill it actually knows — a Skill
## definition plus how many levels this specific unit has bought.
##
## A Node deliberately, not a Resource — levels_purchased is genuine
## per-character progression state that a future "level up" action will
## mutate at runtime, unlike Ability's fields (never mutated, so safely
## shared as one .tres across every unit that has that ability). A
## Resource can't structurally prevent two units from accidentally
## sharing the same saved SkillInstance and silently corrupting each
## other's levels the moment one of them levels up; a Node can't be
## aliased that way at all. Simple enough (no _process, no children of
## its own) that the Node overhead doesn't matter.
##
## Lives as an actual child under a unit's own Skills node (see
## Unit.get_skills/add_skill) — NOT discovered by outside code via a
## hardcoded get_node("Skills") path the way the original design did.
## Unit owns that lookup internally and exposes a plain typed method
## instead, so nothing outside Unit needs to know its internal structure.

@export var skill_data: Skill = null
## Levels purchased beyond the base (1 = just the base attribute+
## difficulty roll, matching GURPS' point-buy progression) — NOT the
## final computed roll target. Named levels_purchased rather than
## skill_level specifically to not read as the same thing
## SkillCheckResult.skill_level means (that one IS the computed target).
@export var levels_purchased: int = 1


func get_relative_skill_level(attribute_value: int) -> int:
	return attribute_value + skill_data.difficulty_level + (levels_purchased - 1)
