extends Node
## Autoload singleton. Register as "DemonCompendium" under Project >
## Project Settings > AutoLoad.
##
## The Cathedral's book of demons, as in Nocturne: you REGISTER a demon you
## own, and later SUMMON a copy of it back for gold. A species that has
## never been registered is a blank page ("?????" in the menu).
##
## ONE ENTRY PER SPECIES. Registering a second Pixie overwrites the first
## Pixie's page, as in the reference.
##
## WHAT A PAGE HOLDS: only the species, for now. An OwnedDemon carries
## nothing else that a summoned copy should inherit (its HP and FP are
## wounds, and a summon arrives whole, as in the reference). When demons
## gain anything of their own — levels, inherited skills — this is where
## it gets recorded, and summon() is where it comes back.
##
## Separate from DemonRoster on purpose: the roster is what you HAVE, this
## is what you have RECORDED, and fusing away a registered demon leaves its
## page in the book.
##
## Persisted via save_state()/load_state() below — see SaveManager.

signal changed

## What a summon costs: SUMMON_COST_PER_RANK_SQUARED × rank². Rank 1 is the
## starting purse, so the first summon is a real choice rather than free.
const SUMMON_COST_PER_RANK_SQUARED: int = 50

## species id -> true. A Dictionary used as a set, so a load can be
## checked against the demon database one id at a time.
var _registered: Dictionary = {}


## Deferred for the same reason as DemonRoster's: this autoload is created
## before SaveManager.
func _ready() -> void:
	_register_persistence.call_deferred()


func _register_persistence() -> void:
	SaveManager.register(&"compendium", self)


## Records this demon's page, replacing any earlier one of its species.
## Returns true if the species already had a page.
func register(owned: OwnedDemon) -> bool:
	var id: String = owned.species.id
	var had_page: bool = _registered.has(id)
	_registered[id] = true
	changed.emit()
	return had_page


func is_registered(species: UnitDefinition) -> bool:
	return species != null and _registered.has(species.id)


func summon_cost(species: UnitDefinition) -> int:
	return SUMMON_COST_PER_RANK_SQUARED * species.rank * species.rank


## Why this species cannot be summoned right now, or "" if it can.
func why_not_summon(species: UnitDefinition) -> String:
	if not is_registered(species):
		return "Not in the compendium."
	if not CurrencyManager.has_gold(summon_cost(species)):
		return "Not enough gold."
	return ""


## Pays and adds a fresh copy to the roster. Null, with nothing spent, if
## why_not_summon() has a reason.
func summon(species: UnitDefinition) -> OwnedDemon:
	if why_not_summon(species) != "":
		return null
	if not CurrencyManager.spend_gold(summon_cost(species)):
		return null
	return DemonRoster.recruit(species)


func save_state() -> Dictionary:
	return {"registered": _registered.keys()}


## An id with no demon behind it any more (a renamed or deleted .tres) is
## dropped with a warning rather than kept as a page nothing can show.
func load_state(state: Dictionary) -> void:
	_registered.clear()
	for id in state.get("registered", []):
		if SpawnableUnitDatabase.find(id) == null:
			push_warning("DemonCompendium.load_state: unknown species id '%s'" % id)
			continue
		_registered[id] = true
	changed.emit()
