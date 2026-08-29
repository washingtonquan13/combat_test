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
## Persisted via save_state()/load_state() below — see SaveManager.

signal gold_changed(new_amount: int)

var gold: int = 50


func save_state() -> Dictionary:
	return {"gold": gold}


## Emits gold_changed — a load is exactly the kind of external change
## any gold-display UI needs to react to, same as add_gold()/spend_gold()
## already do for an ordinary in-session change.
func load_state(state: Dictionary) -> void:
	gold = state.get("gold", gold)
	gold_changed.emit(gold)


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
