class_name FusionGreetings
extends Resource
## What a freshly fused demon says when it opens its eyes.
##
## ONE INTRODUCTION FOR EVERYBODY, ONE REMARK PER PERSONALITY. Nocturne's
## greeting is a fixed sentence with the name and the race dropped in,
## followed by a line in the demon's own voice; writing it per demon would
## be 29 lines that all say the same first half. So the first half is a
## template here, the second half is keyed by UnitDefinition.personality,
## and the cutscene's LineBeat only ever says "{greeting}".
##
## Tokens: {name} is the display name, {order} the race ("Element"). Both
## are filled by FusionRitual before the scene plays, so an edit here shows
## up on the next fusion with no other file touched.

@export_multiline var introduction: String = "I am {name} of the {order} clan."
## Personality (Calm, Wild, ...) -> the line that follows the introduction.
@export var by_personality: Dictionary = {}
## Said when the demon's personality has no entry, or it has none at all.
@export_multiline var fallback_remark: String = "Let us see what you make of me."


## The whole greeting for `demon`, tokens filled.
func greeting_for(demon: UnitDefinition) -> String:
	if demon == null:
		return ""
	var remark: String = str(by_personality.get(demon.personality,
		by_personality.get(String(demon.personality), fallback_remark)))
	var values := {"name": demon.display_name, "order": String(demon.order)}
	return ("%s %s" % [introduction, remark]).format(values).strip_edges()
