class_name SacrificeItemEffect
extends DialogueEffect
## A dialogue/negotiation choice that costs the party a specific item —
## the mirror image of give_item_effect.gd (which GRANTS an item; this
## one consumes one), reached the same way: through
## PartyManager.inventory, the party's shared bag. Generic, not negotiation-
## specific — offering up an item to make a point works the same way in
## any dialogue, not just a demon negotiation.

@export var gear_data: GearItem


func apply(_c: Conversation) -> void:
	if not PartyManager.inventory.consume(gear_data):
		push_warning("SacrificeItemEffect: party inventory has no %s to consume." % gear_data.item_name)


func cost_tag(_c: Conversation) -> String:
	if not gear_data:
		return ""
	return "-1 %s" % gear_data.item_name
