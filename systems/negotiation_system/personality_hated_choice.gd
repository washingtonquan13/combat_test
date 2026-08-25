class_name PersonalityHatedChoice
extends NegotiationChoice
## A personality-table "hated" response — never forgivable, unlike
## PersonalityDislikedChoice. Reuses end_negotiation()'s existing ATTACK
## behavior wholesale (SystemLog narration + demon.use_ability() against
## the actor) rather than duplicating attack logic here; a "hated"
## answer earning a real free attack, not just a worse mood note, is the
## whole point of the category.

func _resolve_next_node_id(_actor: Unit, _target: Unit) -> String:
	NegotiationManager.end_negotiation(NegotiationManager.Outcome.ATTACK)
	return ""
