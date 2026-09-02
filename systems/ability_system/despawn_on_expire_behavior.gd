class_name DespawnOnExpireBehavior
extends StatusBehavior
## Removes the unit outright when this status is removed — meant for a
## per-summon "tracking" status (see SummonEffect.duration_status)
## applied directly to the SUMMONED unit, not the summoner, so
## default_duration ticks down via the existing StatusManager machinery
## on the summon's own turns, completely unchanged — same reasoning as
## DamageOverTimeBehavior reusing on_turn_start rather than a new timer
## system. on_remove fires for any removal (expiry, cure, replace), but
## nothing in this project currently cures or replaces a summon's
## tracking status, so in practice this only ever fires on natural
## duration expiry.

func on_remove(unit: Unit, _active: ActiveStatus, _voluntary: bool = false) -> void:
	unit.expire()


func describe() -> String:
	return "Creature fades away when this expires"
