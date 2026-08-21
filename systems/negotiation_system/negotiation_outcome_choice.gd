class_name NegotiationOutcomeChoice
extends NegotiationChoice
## Ends the negotiation with a specific outcome instead of routing to
## another node — a tree's actual, explicit ending. Reaches directly
## into NegotiationManager to conclude, returning "" only to satisfy
## _resolve_next_node_id's return contract — same established pattern
## SkillCheckChoice/QuickContestChoice already use, reaching into
## DialogueManager from within a choice's own resolution, rather than
## the orchestrator having to interpret a sentinel id specially.
##
## outcome defaults to CONTINUE (enum index 0, Godot's own default for
## an unset export) if an author forgets to set it — NegotiationManager's
## own debug-build validation warns about this specifically, since it
## would otherwise silently fall back to FLEE with no other sign
## anything was wrong.

@export var outcome: NegotiationManager.Outcome = NegotiationManager.Outcome.CONTINUE


func _resolve_next_node_id(_actor: Unit, _target: Unit) -> String:
	NegotiationManager.end_negotiation(outcome)
	return ""
