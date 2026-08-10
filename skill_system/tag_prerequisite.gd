class_name TagPrerequisite
extends PrerequisiteRule
## Requires (or, if forbidden, prohibits) a unit carrying some tag.
## Data-only for now — is_satisfied() isn't implemented (see
## PrerequisiteRule's own header) since this project doesn't have a
## character-tag concept yet (the "units"/"blocking_corpses" scene-tree
## groups are a different mechanism, not a per-unit trait system). Safe
## to author into a Skill.prerequisites tree already; evaluating it just
## refuses until that system exists.

@export var tag_name: String
@export var forbidden: bool = false
