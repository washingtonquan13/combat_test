class_name NegotiatedGoldPrerequisite
extends PrerequisiteRule
## Requires the party to afford THIS negotiation's own rolled amount
## (NegotiationManager.current_gold_amount) rather than a fixed authored
## number — the counterpart to GoldPrerequisite for choices that pay
## SacrificeNegotiatedGoldEffect's own dynamic cost. Needed because that
## amount is rolled per-encounter from the demon's rank: a fixed
## GoldPrerequisite.minimum_amount could authorize a choice the player
## actually can't afford once the real (higher) roll comes back, letting
## SacrificeNegotiatedGoldEffect silently no-op instead of paying.
## No exported fields, same reasoning SacrificeNegotiatedGoldEffect has
## none — there's nothing to author, the amount is never fixed.

func is_satisfied(_unit: Unit) -> bool:
	return CurrencyManager.has_gold(NegotiationManager.current_gold_amount)
