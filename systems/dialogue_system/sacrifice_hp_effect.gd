class_name SacrificeHpEffect
extends DialogueEffect
## A dialogue/negotiation choice that costs the actor real HP — goes
## through the real take_damage() path, genuine stakes, not a cosmetic
## number. Not negotiation-specific despite existing because of it —
## nothing about "sacrifice HP to make a point" is inherently tied to
## negotiating with a demon, so this lives alongside the other generic
## DialogueEffect subclasses (give_item_effect.gd, trigger_combat_effect.gd)
## rather than under systems/negotiation_system/, available to any future
## dramatic dialogue choice unmodified.

@export var amount: int = 5


func apply(actor: Unit, _target: Unit) -> void:
	actor.take_damage(amount)


func cost_tag() -> String:
	if amount <= 0:
		return ""
	return "-%d HP" % amount
