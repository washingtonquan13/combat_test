extends Node
## Autoload singleton. Register as "PartyManager" under
## Project > Project Settings > AutoLoad.
##
## The party's own real membership — an explicit, authoritative roster,
## not a derived scene-tree query. UnitQuery.core_party_units() (the
## live "units" group filtered by is_player_controlled()/summoned_by)
## still exists and still works unchanged for every EXISTING consumer —
## this is deliberately additive, not a migration. But anything NEW that
## needs to ask "who's actually in my party" should ask THIS, not
## re-derive the same filter: a live scene query can't answer that
## question once a unit might exist without being placed in the current
## scene at all (a future character-creation flow, a debug add/remove
## menu, eventual save/load) — exactly the "stop relying on hardcoded
## party members" gap this exists to start closing.
##
## Also owns which single member, if any, is currently designated the
## player character / party leader — distinguishing "the protagonist"
## from an ordinary party member for the first time in this project.
##
## Both leader and members are bare Unit references, same shape as
## Unit.summoned_by/owned_demon — NOT a new data Resource. A future
## data-only representation of a full party member (needed for real
## destroy-and-reload area travel — see SceneManager's own header) is a
## separate, larger effort this intentionally does not attempt here;
## "who's in the party"/"who's the leader" and "what fully describes a
## party member" are cleanly separable questions.

signal member_added(unit: Unit)
signal member_removed(unit: Unit)
signal leader_changed(unit: Unit)

var members: Array[Unit] = []
var leader: Unit = null


## Silently refused (with a warning) for anything that isn't a core party
## unit — mirrors the exact guard SelectionManager.select() already
## applies for "can this unit ever be treated as ours at all." Idempotent
## — adding an already-present member is a safe no-op, same convention
## SummonDemonEffect/DemonRoster already use elsewhere.
func add_member(unit: Unit) -> void:
	if not unit.is_player_controlled() or unit.summoned_by != null:
		push_warning("PartyManager.add_member refused: %s isn't a core party member." % unit.name)
		return
	if unit in members:
		return
	members.append(unit)
	unit.died.connect(_on_member_died)
	member_added.emit(unit)


## Removes the roster ENTRY only — does not touch the live Unit node or
## the scene tree at all. Deliberately separate concerns: whether a
## dismissed/removed party member's node should be freed, hidden, or
## left standing in the world is a decision for whatever future feature
## actually calls this (the debug add/remove menu, e.g.), not something
## this file should assume. Clears leader too if the removed unit WAS
## the leader — you can't lead a party you're not in.
func remove_member(unit: Unit) -> void:
	if unit not in members:
		return
	members.erase(unit)
	if unit.died.is_connected(_on_member_died):
		unit.died.disconnect(_on_member_died)
	if leader == unit:
		leader = null
		leader_changed.emit(null)
	member_removed.emit(unit)


func _on_member_died(unit: Unit) -> void:
	remove_member(unit)


func is_member(unit: Unit) -> bool:
	return unit in members


## Must already be a member — leader is a role WITHIN the roster, not an
## independent designation with its own separate validity check.
func set_leader(unit: Unit) -> void:
	if not is_member(unit):
		push_warning("PartyManager.set_leader refused: %s isn't a party member." % unit.name)
		return
	if leader == unit:
		return
	leader = unit
	leader_changed.emit(unit)


func is_leader(unit: Unit) -> bool:
	return unit != null and unit == leader
