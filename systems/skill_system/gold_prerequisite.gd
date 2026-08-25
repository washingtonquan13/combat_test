class_name GoldPrerequisite
extends PrerequisiteRule
## Requires the party to be able to afford a minimum amount of gold —
## global party state, not per-character, same reasoning FlagPrerequisite
## already states for ignoring its own unit argument. Gates a choice's
## VISIBILITY: a player who can't afford it never sees "Offer 20 gold"
## in the list at all, rather than seeing it fail on click. For a
## negotiation's own dynamically-rolled amount, see
## NegotiatedGoldPrerequisite instead — a fixed minimum_amount here can't
## track that per-encounter number.

@export var minimum_amount: int = 0


func is_satisfied(_unit: Unit) -> bool:
	return CurrencyManager.has_gold(minimum_amount)
