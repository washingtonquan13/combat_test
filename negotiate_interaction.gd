class_name NegotiateInteraction
extends InteractionOption
## Right-click "Negotiate" — the first InteractionOption to check combat
## state directly (neither AttackInteraction nor TalkInteraction do:
## Attack works both in/out of combat by design, Talk's combat-block
## lives inside DialogueManager itself). Negotiation is the opposite of
## Talk's own gating: combat-ONLY, hostile-only, and further gated on
## target.negotiable so it only ever appears on units actually authored
## to be negotiable, not every hostile unit in the game.

func is_available(actor: Unit, target) -> bool:
	if not target is Unit:
		return false
	var unit_target: Unit = target
	return CombatManager.in_combat and actor.is_hostile_to(unit_target) and unit_target.negotiable


func execute(actor: Unit, target) -> void:
	NegotiationManager.start_negotiation(actor, target)
