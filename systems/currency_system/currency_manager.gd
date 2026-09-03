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


## Registered from HERE rather than named by SaveManager: adding a system
## that persists should never be an edit to the save system again, and a
## hand-maintained list somewhere else is a second place to remember
## something.
##
## DEFERRED because this autoload is created BEFORE SaveManager (see
## project.godot's [autoload] order) — the `SaveManager` identifier cannot
## be resolved yet while this _ready() runs. A deferred call lands once
## every autoload is up, which is still long before anything can ask for a
## save.
func _ready() -> void:
	_register_persistence.call_deferred()


## No `after`: load_state() below sets one int and emits gold_changed,
## whose only listener is a label in PartyOverview (see
## party_overview.gd's _on_gold_changed) — nothing that reads another
## system's restored state.
func _register_persistence() -> void:
	SaveManager.register(&"currency", self)


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
