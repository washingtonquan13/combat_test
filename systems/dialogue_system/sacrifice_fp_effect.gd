class_name SacrificeFpEffect
extends DialogueEffect
## FP sibling to SacrificeHpEffect — see that file's own header for why
## this lives here rather than under systems/negotiation_system/.
##
## Needs its own amount <= 0 guard, unlike SacrificeHpEffect: Unit has
## no take_damage()-equivalent floor for FP, so a negative amount here
## would silently ADD fp instead of spending it (current_fp - (-5) =
## current_fp + 5) if left unguarded.

@export var amount: int = 5


func apply(actor: Unit, _target: Unit) -> void:
	if amount <= 0:
		return
	actor.current_fp = maxi(actor.current_fp - amount, 0)
	SystemLog.print("%s spends %d FP." % [LogFormat.unit_name(actor), amount])
