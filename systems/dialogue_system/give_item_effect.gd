class_name GiveItemEffect
extends DialogueEffect
## Instantiates a fresh Item from gear_data and drops it in the party's
## shared inventory — the "quest reward" case named in
## dialogue_system_bg3_gap_analysis.md. Targets the actor's own party
## (via PartyOverview, found through the "party_overview" group rather
## than a direct reference — this is a Resource, authored data with no
## scene-tree position of its own to hold a NodePath against, same
## constraint FlagPrerequisite sidesteps by going through an autoload
## instead. PartyOverview isn't one, so a group is this project's next
## existing idiom for "some other script needs to find this by role,
## not by exact tree position" — see the "units"/"ladders"/
## "blocking_corpses" groups already used the same way).
##
## No StashComponent/shop-opening sibling yet — that would need a
## specific container instance a Resource has no clean way to reference
## either, and no scene actually needs it yet. Add it once one does,
## same restraint skill_check_choice.gd's own header already argues for.

const ITEM_SCENE: PackedScene = preload("res://systems/inventory_system/item.tscn")

@export var gear_data: GearItem


func apply(actor: Unit, _target: Unit) -> void:
	var party_overview: PartyOverview = actor.get_tree().get_first_node_in_group("party_overview")
	if not party_overview:
		push_error("GiveItemEffect: no PartyOverview in the 'party_overview' group.")
		return

	var item: Item = ITEM_SCENE.instantiate()
	item.definition = gear_data
	if not party_overview.get_inventory().auto_place_item(item):
		push_warning("GiveItemEffect: party inventory has no room for %s." % gear_data.item_name)
		item.queue_free()
