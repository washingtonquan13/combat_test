class_name SkillCategoryPrerequisite
extends PrerequisiteRule
## Requires ANY skill in some category to be at least min_value. Data-only
## for now — is_satisfied() isn't implemented (see PrerequisiteRule's own
## header) since Skill doesn't have a category field yet. Safe to author
## into a Skill.prerequisites tree already; evaluating it just refuses
## until Skill gains a category and this can search SkillDatabase for it.

@export var category: String
@export var min_value: int
