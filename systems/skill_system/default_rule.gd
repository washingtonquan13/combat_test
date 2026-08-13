class_name DefaultRule
extends Resource
## One entry in Skill.defaults — "this skill can also be attempted at
## <source>'s value + modifier, if you haven't trained it (or even if you
## have, when the default beats your trained level)." source_name is an
## attribute name (Unit.get_attribute_value) or another skill's name
## (SkillDatabase-resolved), depending on source_type. See
## SkillCalculator.get_skill_level for how a skill's defaults list gets
## turned into an actual number.

enum SourceType {
	ATTRIBUTE,
	SKILL,
}

@export var source_type: SourceType = SourceType.ATTRIBUTE
@export var source_name: String = ""
@export var modifier: int = 0
