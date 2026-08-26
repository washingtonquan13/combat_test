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

var _owned: Array[OwnedDemon] = []

## Party-wide cap on how many demons can be actively fielded at once —
## read by SummonDemonEffect.apply(). Debug-adjustable for now (see the
## demon compendium panel's debug row) — the real long-term driver is
## meant to be party progression, but this project has no progression/
## XP system yet. Whatever eventually computes that should assign
## directly into this field rather than adding a parallel value; nothing
## else needs to change.
var max_active_summons: int = 3


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
func is_fielded(owned_demon: OwnedDemon) -> bool:
	for unit in UnitQuery.all_units(get_tree()):
		if unit.is_alive() and unit.owned_demon == owned_demon:
			return true
	return false


## The full roster, individual entries included — the compendium
## panel's own listing, one row per instance, not grouped by species.
func all_owned() -> Array[OwnedDemon]:
	return _owned.duplicate()
