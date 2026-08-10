class_name AdvantagePrerequisite
extends PrerequisiteRule
## Requires (or, if forbidden, prohibits) an advantage at some minimum
## value. Data-only for now — is_satisfied() isn't implemented (see
## PrerequisiteRule's own header) since this project doesn't have an
## advantage system yet. Safe to author into a Skill.prerequisites tree
## already; evaluating it just refuses until that system exists.

@export var advantage_name: String
@export var min_value: int = 0
@export var forbidden: bool = false
