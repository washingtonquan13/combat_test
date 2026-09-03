class_name SacrificeItemEffect
extends DialogueEffect
## A dialogue/negotiation choice that costs the party a specific item —
## the mirror image of give_item_effect.gd (which GRANTS an item; this
## one consumes one), reached the same way: via the "party_overview"
## group, since this is a Resource with no scene-tree position of its
## own to hold a direct reference against. Generic, not negotiation-
## specific — offering up an item to make a point works the same way in
## any dialogue, not just a demon negotiation.

@export var gear_data: GearItem


func apply(actor: Unit, _target: Unit) -> void:
	var party_overview: PartyOverview = actor.get_tree().get_first_node_in_group("party_overview")
	if not party_overview:
		push_error("SacrificeItemEffect: no PartyOverview in the 'party_overview' group.")
		return
	if not party_overview.get_inventory().consume_item(gear_data):
		push_warning("SacrificeItemEffect: party inventory has no %s to consume." % gear_data.item_name)


func cost_tag() -> String:
	if not gear_data:
		return ""
	return "-1 %s" % gear_data.item_name
