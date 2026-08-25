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
##
## RECRUIT/HEAL_PLAYER are semi-deterministic, not guaranteed — see
## NegotiationManager.roll_success()'s own doc comment for why. FLEE/
## ATTACK stay fully authored: those already read as "the negotiation
## went badly" or "this demon just wants to be left alone," neither of
## which needs added suspense the way "will they actually join me" does.

@export var outcome: NegotiationManager.Outcome = NegotiationManager.Outcome.CONTINUE


func _resolve_next_node_id(_actor: Unit, _target: Unit) -> String:
	var resolved: NegotiationManager.Outcome = outcome
	var is_chance_gated: bool = outcome == NegotiationManager.Outcome.RECRUIT \
			or outcome == NegotiationManager.Outcome.HEAL_PLAYER
	if is_chance_gated and not NegotiationManager.roll_success():
		SystemLog.print("Despite everything, the demon hesitates and backs away.")
		resolved = NegotiationManager.Outcome.FLEE
	NegotiationManager.end_negotiation(resolved)
	return ""
