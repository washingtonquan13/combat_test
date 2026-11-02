class_name ItemOwnedPrerequisite
extends PrerequisiteRule
## Requires the party to own a specific item — anywhere in the party's
## shared bag (PartyManager.inventory), the same one GiveItemEffect fills.

@export var gear_data: GearItem


func is_satisfied(_unit: Unit) -> bool:
	return PartyManager.inventory.has(gear_data)
