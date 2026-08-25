class_name PersonalityDislikedChoice
extends NegotiationChoice
## A personality-table "disliked" response — the demon may let it slide
## ONCE per negotiation (see NegotiationManager.try_forgive()); a second
## disliked answer in the same negotiation ends things peacefully. Never
## used for "hated" answers — see PersonalityHatedChoice, which is never
## forgivable and ends things hostile rather than peaceful, matching the
## real, confirmed distinction between the two categories.

@export var next_node_id: String = ""


func _resolve_next_node_id(_actor: Unit, _target: Unit) -> String:
	if NegotiationManager.try_forgive():
		return next_node_id
	NegotiationManager.end_negotiation(NegotiationManager.Outcome.FLEE)
	return ""
