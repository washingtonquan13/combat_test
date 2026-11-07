class_name MoodPrerequisite
extends PrerequisiteRule
## Requires the conversation's hidden mood variable to have reached a
## minimum — negotiation-only by nature (a negotiation's opening effect
## is what sets the mood variable), but lives here anyway alongside FlagPrerequisite/
## GoldPrerequisite: this folder is already documented as "a leftover of
## PrerequisiteRule having been built for skills first," not
## skill-specific, and every PrerequisiteRule subclass belongs together
## regardless of which system actually uses it. Mood is per-conversation
## state, not per-character, so outside a conversation there is none to
## reach and the answer is no.

@export var minimum_mood: int = 0


func is_satisfied(_unit: Unit) -> bool:
	return false


func is_satisfied_in(c: Conversation) -> bool:
	return int(c.vars.get("mood", 0)) >= minimum_mood
