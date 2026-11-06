class_name ShiftMoodEffect
extends DialogueEffect
## Raises or lowers the conversation's hidden mood variable (set up by
## NegotiationOpeningEffect, read by MoodPrerequisite). Negotiation-flavored
## by nature, which is why this lives in systems/negotiation_system/
## rather than with the generic Sacrifice*Effect family.
##
## No numeric meter in the UI (no art budget for a reaction-icon
## indicator), but NOT silent either: every change is narrated as a
## transcript aside, matching how real modern SMT negotiation (Strange
## Journey's TALK system, not Nocturne's more opaque one) surfaces mood —
## no bar, but real text feedback the player can read and react to. The
## aside carries the new mood so a presenter can tint by it (see
## negotiation_panel.gd), and the negotiation's echo to SystemLog puts
## the note there too.

@export var amount: int = 0


func apply(c: Conversation) -> void:
	shift(c, amount)


## Shared with VolatileMoodEffect — the only difference between the two is
## where the amount comes from.
static func shift(c: Conversation, delta: int) -> void:
	var mood: int = int(c.vars.get("mood", 0)) + delta
	c.vars["mood"] = mood

	var note: String = ""
	if delta >= 3:
		note = "The demon's mood brightens considerably."
	elif delta > 0:
		note = "The demon's mood seems to improve."
	elif delta <= -3:
		note = "That visibly sours the demon's mood."
	elif delta < 0:
		note = "The mood turns a bit awkward..."

	if note != "":
		c.record("", note, {"tag": &"mood", "mood": mood})
