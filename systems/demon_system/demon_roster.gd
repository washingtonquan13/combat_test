extends Node
## Autoload singleton. Register as "DemonRoster" under Project > Project
## Settings > AutoLoad.
##
## Every demon the player currently owns, as real individual entries —
## deliberately NOT a per-species count. Two copies of the same species
## are two separate array entries with independently-tracked HP/FP (see
## OwnedDemon) — owning multiple Pixies is just owning multiple Pixies,
## no artificial per-species cap. Not persisted to disk, same as
## FlagManager — this project has no save system yet.
##
## Ownership is a separate concern from "currently summoned" — a live
## demon Unit on the field points back at its OwnedDemon via
## Unit.owned_demon, but that instance stays in _owned the whole time
## it's out. Dismissing or ending a fight doesn't touch this array at
## all; only release() (fusion consuming a parent, or a real combat
## death — see UnitCombat.take_damage()) does.
##
## Persisted via save_state()/load_state() below — see SaveManager.
## Known, accepted gap: a demon that's actively FIELDED (a live Unit
## whose owned_demon points here) at save time is not re-summoned on
## load — only ownership round-trips, not "currently on the field."
## SaveManager.can_save() only allows saving in EXPLORATION/OVERWORLD,
## and summoning is a combat action, so this is reachable only through
## the debug summon path, not ordinary play.

var _owned: Array[OwnedDemon] = []

## Default (and new-game/empty-save) value for max_active_summons — see
## load_state() below. Before this was a named constant,
## `max_active_summons = state.get("max_active_summons", max_active_summons)`
## made a save whose "demons" section is {} a no-op instead of a reset, so
## a debug-adjusted cap (see the compendium panel's debug row) survived
## past a new game.
const DEFAULT_MAX_ACTIVE_SUMMONS: int = 3

## Party-wide cap on how many demons can be actively fielded at once —
## read by SummonDemonEffect.apply(). Debug-adjustable for now (see the
## demon compendium panel's debug row) — the real long-term driver is
## meant to be party progression, but this project has no progression/
## XP system yet. Whatever eventually computes that should assign
## directly into this field rather than adding a parallel value; nothing
## else needs to change.
var max_active_summons: int = DEFAULT_MAX_ACTIVE_SUMMONS


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


## No `after`: load_state() below resolves each entry's species through
## SpawnableUnitDatabase — a resource database, not a saved system — and
## reads nothing that FlagManager, PartyManager, CurrencyManager or the
## party Inventory restore. Ownership and party membership are separate
## records with no reference between them in the save file.
func _register_persistence() -> void:
	SaveManager.register(&"demons", self)


## Creates a fresh, full-HP/FP OwnedDemon and adds it to the roster —
## used by both a fusion result and negotiation's Recruit outcome.
func recruit(species: UnitDefinition) -> OwnedDemon:
	var owned := OwnedDemon.new()
	owned.species = species
	owned.current_hp = species.max_hp
	owned.current_fp = species.max_fp
	_owned.append(owned)
	return owned


## Removes exactly this one instance — fusion consuming a parent, or a
## summoned demon reduced to 0 HP in real combat (permanently lost, per
## design). Silently no-ops if not present.
func release(owned_demon: OwnedDemon) -> void:
	_owned.erase(owned_demon)


func is_owned(owned_demon: OwnedDemon) -> bool:
	return _owned.has(owned_demon)


## Whether this specific roster entry is currently fielded as a live Unit
## anywhere in the scene — the check SummonDemonEffect.apply() and
## hotbar_slot.gd's demon picker were both missing, which let the exact
## same OwnedDemon be summoned more than once at a time: nothing but the
## aggregate max_active_summons count gated a second summon of an
## ALREADY-fielded entry, so two (or three) live Units could end up
## sharing one OwnedDemon reference. Scans the same "units" group
## UnitQuery already reads rather than DemonRoster tracking its own
## separate fielded-set — Unit.owned_demon is already the one source of
## truth for "is this entry out right now."
## Global on purpose. "Is this entry out right now" is a question about
## the ROSTER, not about a place: a demon fielded in an area the player
## is not looking at is still fielded, and scoping this to the focused
## world would let the same OwnedDemon be summoned a second time
## somewhere else — the exact double-summon this function exists to
## prevent.
func is_fielded(owned_demon: OwnedDemon) -> bool:
	for unit in UnitQuery.all_units(get_tree()):
		if unit.is_alive() and unit.owned_demon == owned_demon:
			return true
	return false


## The full roster, individual entries included — the compendium
## panel's own listing, one row per instance, not grouped by species.
func all_owned() -> Array[OwnedDemon]:
	return _owned.duplicate()


## species.id, not a direct UnitDefinition reference — same
## resource-by-id convention every other saved reference uses (see
## SpawnableUnitDatabase.find(), the counterpart this is read back
## through).
func save_state() -> Dictionary:
	var entries: Array[Dictionary] = []
	for owned in _owned:
		entries.append({
			"species_id": owned.species.id if owned.species else "",
			"current_hp": owned.current_hp,
			"current_fp": owned.current_fp,
			"has_been_summoned": owned.has_been_summoned,
		})
	return {
		"owned": entries,
		"max_active_summons": max_active_summons,
	}


func load_state(state: Dictionary) -> void:
	_owned.clear()
	for entry in state.get("owned", []):
		var species: UnitDefinition = SpawnableUnitDatabase.find(entry.get("species_id", ""))
		if not species:
			push_warning("DemonRoster.load_state: unknown species id '%s'" % entry.get("species_id"))
			continue
		var owned := OwnedDemon.new()
		owned.species = species
		owned.current_hp = entry.get("current_hp", species.max_hp)
		owned.current_fp = entry.get("current_fp", species.max_fp)
		owned.has_been_summoned = entry.get("has_been_summoned", false)
		_owned.append(owned)
	max_active_summons = state.get("max_active_summons", DEFAULT_MAX_ACTIVE_SUMMONS)
