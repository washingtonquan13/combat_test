class_name MoodPrerequisite
extends PrerequisiteRule
## Requires the current negotiation's hidden mood to have reached a
## minimum — negotiation-only by nature (reads NegotiationManager
## directly), but lives here anyway alongside FlagPrerequisite/
## GoldPrerequisite: this folder is already documented as "a leftover of
## PrerequisiteRule having been built for skills first," not
## skill-specific, and every PrerequisiteRule subclass belongs together
## regardless of which system actually uses it. Ignores its own unit
## argument for the same reason FlagPrerequisite does — mood is
## per-negotiation state, not per-character.

@export var minimum_mood: int = 0


func is_satisfied(_unit: Unit) -> bool:
	return NegotiationManager.current_mood >= minimum_mood
