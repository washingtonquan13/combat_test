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


## The full roster, individual entries included — the compendium
## panel's own listing, one row per instance, not grouped by species.
func all_owned() -> Array[OwnedDemon]:
	return _owned.duplicate()
