class_name Skill
extends Resource
## One skill's definition — difficulty, what it defaults from, and what's
## required to learn it. A Skill only describes what's true about the
## skill itself; whether a given unit has trained it lives on
## SkillInstance instead, and computing an effective level for a unit is
## SkillCalculator's job, not this resource's.
##
## Theoretically infinite by design: SkillDatabase resolves a skill name
## to one of these by scanning res://data/skills/* rather than any
## hardcoded list, so adding a new skill to the game is just dropping a
## new .tres file in that folder — no code changes anywhere.

enum Difficulty {
	EASY = 0,
	AVERAGE = -1,
	HARD = -2,
	VERY_HARD = -3,
}

@export var skill_name: String = "Unnamed Skill"
@export var controlling_attribute: String = "DX"
@export var difficulty_level: Difficulty = Difficulty.AVERAGE
@export var defaults: Array[DefaultRule] = []
## Single top-level requirement, or null for none. Compose multiple
## requirements with a CountPrerequisite (required_count = -1 for "all
## of," = 1 for "any of," or any specific N-of-M) rather than a separate
## AllOf/AnyOf type — CountPrerequisite already nests inside itself
## arbitrarily deep, since it's a PrerequisiteRule like everything else,
## so a second composition mechanism would only compete with it.
@export var prerequisites: PrerequisiteRule = null
@export var learned_only: bool = false
@export_multiline var description: String = ""
