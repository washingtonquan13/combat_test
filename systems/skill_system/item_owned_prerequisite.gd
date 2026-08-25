class_name ItemOwnedPrerequisite
extends PrerequisiteRule
## Requires the party to own a specific item — unlike FlagPrerequisite/
## GoldPrerequisite, needs the actual unit argument (not just global
## autoload state) to reach the party's Inventory via the same
## "party_overview" group lookup GiveItemEffect.apply() already uses;
## a Resource has no scene-tree position of its own to hold a direct
## reference against.

@export var gear_data: GearItem


func is_satisfied(unit: Unit) -> bool:
	var party_overview: PartyOverview = unit.get_tree().get_first_node_in_group("party_overview")
	return party_overview and party_overview.get_inventory().has_item(gear_data)
