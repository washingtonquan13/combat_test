class_name SacrificeGoldEffect
extends DialogueEffect
## A dialogue/negotiation choice that costs the party a fixed, authored
## amount of gold — same "real stakes, not cosmetic" reasoning as
## sacrifice_hp_effect.gd/sacrifice_fp_effect.gd, and living alongside
## them for the same reason: paying a cost to make a point isn't
## inherently negotiation-specific (a toll, a bribe, a quest turn-in),
## so this stays a generic DialogueEffect rather than moving under
## systems/negotiation_system/. For a negotiation's own rank-scaled,
## randomly-rolled amount, see SacrificeNegotiatedGoldEffect instead —
## that one reads NegotiationManager state and belongs there.

@export var amount: int = 0


func apply(_actor: Unit, _target: Unit) -> void:
	CurrencyManager.spend_gold(amount)


func cost_tag() -> String:
	if amount <= 0:
		return ""
	return "-%d gold" % amount
