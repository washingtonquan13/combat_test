class_name SacrificeNegotiatedGoldEffect
extends DialogueEffect
## Pays whatever this encounter's own rolled gold amount is — the
## conversation's gold variable, rolled once per negotiation from the
## demon's rank by NegotiationOpeningEffect. Used for BOTH directions of
## the same mechanic: the player offering gold to end things peacefully,
## or paying a demon's own demand — same amount either way, just authored
## into different choices. Unlike the generic, fixed-amount
## SacrificeGoldEffect in systems/dialogue_system/.


func apply(c: Conversation) -> void:
	CurrencyManager.spend_gold(int(c.vars.get("gold", 0)))


## Reads the same gold variable apply() spends — rolled at the start of
## the negotiation, before either the offering or the demand choice is
## ever shown, so previewing it here can't disagree with what actually
## gets spent.
func cost_tag(c: Conversation) -> String:
	var gold: int = int(c.vars.get("gold", 0))
	if gold <= 0:
		return ""
	return "-%d gold" % gold
