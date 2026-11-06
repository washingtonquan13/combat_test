class_name SpendPardonEffect
extends DialogueEffect
## Carried by a personality-table "disliked" response — the demon may let
## it slide ONCE per negotiation (the pardon variable, set to 1 by
## NegotiationOpeningEffect); a second disliked answer in the same
## negotiation ends things peacefully with FLEE. Never used for "hated"
## answers — those carry a NegotiationOutcomeEffect set to ATTACK, never
## forgivable and ending hostile rather than peaceful, matching the real,
## confirmed distinction between the two categories.


func apply(c: Conversation) -> void:
	var pardon: int = int(c.vars.get("pardon", 0))
	if pardon > 0:
		c.vars["pardon"] = pardon - 1
		c.record("", "The demon lets that one slide... this time.")
		return
	NegotiationOutcomeEffect.conclude(c, NegotiationOutcomeEffect.Outcome.FLEE)
