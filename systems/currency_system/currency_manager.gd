extends Node
## Autoload singleton. Register as "CurrencyManager" under Project > Project
## Settings > AutoLoad.
##
## Party-wide gold as a plain counter — deliberately NOT a spatial
## Inventory item, even though Item.gear_data's own doc comment leaves
## room for currency-as-grid-item ("Null for a non-gear item (currency,
## a plain consumable)"). The Inventory grid is a spatial drag-drop
## system (cell size, stacking, ghost previews) — real complexity for no
## gain against "can the party afford 20 gold." A plain int, spent/
## granted through this autoload, matches how DemonRoster/FlagManager
## already track their own party-wide state.
##
## Not persisted to disk, same as FlagManager/DemonRoster — this project
## has no save system yet.

signal gold_changed(new_amount: int)

var gold: int = 50


func add_gold(amount: int) -> void:
	gold += amount
	gold_changed.emit(gold)


## False and unchanged if the party can't afford it. Callers that need
## to gate on affordability should prefer has_gold() before ever letting
## the player reach a choice that calls this (see GoldPrerequisite), but
## this stays safe against negative gold regardless.
func spend_gold(amount: int) -> bool:
	if amount > gold:
		return false
	gold -= amount
	gold_changed.emit(gold)
	return true


func has_gold(amount: int) -> bool:
	return gold >= amount
