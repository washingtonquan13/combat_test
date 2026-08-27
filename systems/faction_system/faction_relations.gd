extends Node
## Autoload singleton. Register as "FactionRelations" under
## Project > Project Settings > AutoLoad.
##
## The whole hostility model, replacing what used to be a bare
## faction != other.faction comparison hardcoded inline in
## Unit.is_hostile_to(). Two layers:
##   - A base, persistent relation between two FACTIONS (not individual
##     units) — Hostile/Neutral/Allied. Authored content only, via
##     set_relation(); nothing in this file ever calls it automatically.
##   - A temporary-hostile override on top, which is what an actual
##     provoked attack escalates (see escalate_to_temporary_hostile) —
##     modeled directly on Baldur's Gate 3's own confirmed architecture
##     (SetRelation vs. SetRelationTemporaryHostile): attack-provoked
##     hostility is always temporary, never a permanent relation change,
##     and it clears once the resulting combat ends.
##
## Three tiers, not BG3's four — deliberately dropping "Persistent
## Neutral" (BG3's guard against hostility cascading transitively through
## an alliance graph). That failure mode needs an Allied pair between two
## DIFFERENT factions plus a transitive join rule; neither exists in this
## project today (CombatManager's own aggro-pull is same-faction-only).
## Add it if that ever changes — not before.
##
## &"neutral" is a hardcoded wildcard here, not an authored relation —
## any faction paired with it reads as Neutral with zero table entries
## needed. This is exactly where Unit.is_hostile_to()'s own neutral
## carve-out used to live; moved here so hostility rules live in exactly
## one place. Requiring an explicit row per (faction, neutral) pair
## instead would silently break the instant a new faction is added and
## someone forgets to author its row.

enum Tier { HOSTILE, NEUTRAL, ALLIED }

const UNIVERSAL_NEUTRAL_FACTION: StringName = &"neutral"

signal relation_changed(faction_a: StringName, faction_b: StringName, tier: Tier)
signal temporary_hostility_started(faction_a: StringName, faction_b: StringName)
signal temporary_hostilities_cleared()

var _base: Dictionary = {}  # pair-key String -> Tier
var _temporary_hostile: Dictionary = {}  # pair-key String -> true


func _ready() -> void:
	CombatManager.combat_ended.connect(_on_combat_ended)


## Effective relation right now — base tier, or Hostile if a temporary
## escalation is active, whichever the caller actually needs; see
## is_hostile() below for the common case.
func get_relation(faction_a: StringName, faction_b: StringName) -> Tier:
	if faction_a == faction_b:
		return Tier.ALLIED
	if is_temporary_hostile(faction_a, faction_b):
		return Tier.HOSTILE
	if faction_a == UNIVERSAL_NEUTRAL_FACTION or faction_b == UNIVERSAL_NEUTRAL_FACTION:
		return Tier.NEUTRAL
	return _base.get(_pair_key(faction_a, faction_b), Tier.HOSTILE)  # unlisted pair defaults hostile, matching the old bare != rule


func is_hostile(faction_a: StringName, faction_b: StringName) -> bool:
	return get_relation(faction_a, faction_b) == Tier.HOSTILE


## Permanent — authored/scripted content only (e.g. a quest resolution).
## Never called automatically by combat itself; an attack always goes
## through escalate_to_temporary_hostile() instead, matching BG3's own
## confirmed rule that attack-provoked hostility is never permanent.
func set_relation(faction_a: StringName, faction_b: StringName, tier: Tier) -> void:
	_base[_pair_key(faction_a, faction_b)] = tier
	relation_changed.emit(faction_a, faction_b, tier)


func is_temporary_hostile(faction_a: StringName, faction_b: StringName) -> bool:
	return _temporary_hostile.has(_pair_key(faction_a, faction_b))


## The reaction to "attacker just attacked a not-currently-hostile
## target" — pushes the two FACTIONS into Hostile until the resulting
## combat ends. No-op for a same-faction pair (friendly fire must never
## escalate — this project's affects_allies-capable AoE depends on that
## staying true) and no-op if the pair is already hostile.
func escalate_to_temporary_hostile(faction_a: StringName, faction_b: StringName) -> void:
	if faction_a == faction_b or is_hostile(faction_a, faction_b):
		return
	_temporary_hostile[_pair_key(faction_a, faction_b)] = true
	temporary_hostility_started.emit(faction_a, faction_b)


## Only one combat can ever run at a time in this project (CombatManager
## is a single global turn_order), so "clears once combat between those
## specific parties has ended" (the real BG3 rule) and "clears when THE
## combat ends" are the same statement here. Revisit if this project ever
## grows simultaneous independent encounters.
func _on_combat_ended(_winning_faction: StringName) -> void:
	if _temporary_hostile.is_empty():
		return
	_temporary_hostile.clear()
	temporary_hostilities_cleared.emit()


static func _pair_key(a: StringName, b: StringName) -> String:
	return "%s|%s" % [a, b] if String(a) <= String(b) else "%s|%s" % [b, a]
