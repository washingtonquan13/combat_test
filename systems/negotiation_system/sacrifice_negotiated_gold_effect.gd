class_name SacrificeNegotiatedGoldEffect
extends DialogueEffect
## Pays whatever this encounter's own rolled gold amount is — see
## NegotiationManager.current_gold_amount, computed once per negotiation
## from the demon's rank. Used for BOTH directions of the same
## mechanic: the player offering gold to end things peacefully, or
## paying a demon's own demand — same amount either way, just authored
## into different choices. Negotiation-specific by nature (reads
## NegotiationManager directly), unlike the generic, fixed-amount
## SacrificeGoldEffect in systems/dialogue_system/.

func apply(_actor: Unit, _target: Unit) -> void:
	CurrencyManager.spend_gold(NegotiationManager.current_gold_amount)
