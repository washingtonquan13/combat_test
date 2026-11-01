class_name OwnedDemon
extends Resource
## ONE individual demon the player actually owns — not the same thing
## as its species. Two Pixies are two separate OwnedDemon instances,
## each tracking its own HP/FP pools independently, so
## damage one takes in battle doesn't vanish the moment it's dismissed
## (see DismissEffect, which syncs a live Unit's state back here) and
## doesn't heal for free just by re-summoning it (see
## SummonDemonEffect, which reads these values back out instead of
## always starting a summon at full health).
##
## Deliberately dumb data — no logic of its own, same as QuestStage.
## DemonRoster owns the array these live in and the identity-based
## add/remove operations (an OwnedDemon has no id of its own; instance
## equality via the roster's own Array is enough, since nothing needs
## to look one up by name — you always already have the reference from
## whichever list the player clicked into).

@export var species: UnitDefinition
## This demon's own stat state in UnitStats.to_dict() shape — today only
## "pools" (current HP/FP), since an owned demon's bases are its species'.
## Empty means a fresh recruit: summoned at full.
@export var stats: Dictionary = {}
## Purely informational for now (e.g. a "battle-tested" indicator in
## the compendium UI) — no mechanical effect is specified yet, so none
## is built. Still real per-instance state, which is exactly why this
## whole class exists instead of a bare species reference.
@export var has_been_summoned: bool = false
## Died in battle. Stays in the roster rather than being released so it
## can be revived later; until then it can't be summoned.
@export var is_dead: bool = false


## Current value of a pool — HP, FP. A pool this demon has no record of
## is full.
func get_pool(id: StringName) -> int:
	var pools: Dictionary = stats.get("pools", {})
	return int(pools.get(String(id), species.stat_value(id) if species else 0))


## Records a live unit's pools — on dismissal, and when a fielded demon's
## world is freed.
func capture_pools(unit: Unit) -> void:
	stats = {"pools": unit.stats_to_dict().get("pools", {})}


## Back to full — a fresh recruit.
func fill_pools() -> void:
	stats = {}
