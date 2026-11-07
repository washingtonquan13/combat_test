class_name SacrificeFpEffect
extends DialogueEffect
## FP sibling to SacrificeHpEffect — see that file's own header for why
## this lives here rather than under systems/negotiation_system/.
##
## Needs its own amount <= 0 guard, unlike SacrificeHpEffect: Unit has
## no take_damage()-equivalent floor for FP, so a negative amount here
## would silently ADD fp instead of spending it (FP - (-5) = FP + 5) if
## left unguarded.

@export var amount: int = 5


func apply(c: Conversation) -> void:
	if amount <= 0:
		return
	var actor: Unit = c.cast.get("player") as Unit
	actor.set_pool(StatIds.FP, maxi(actor.get_pool(StatIds.FP) - amount, 0))
	SystemLog.print("%s spends %d FP." % [LogFormat.unit_name(actor), amount])


func cost_tag(_c: Conversation) -> String:
	if amount <= 0:
		return ""
	return "-%d FP" % amount
