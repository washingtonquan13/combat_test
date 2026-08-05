class_name RemoveStatusEffect
extends AbilityEffect
## Strips a specific StatusEffect from target on use — a cure/dispel.
## Bridges to StatusManager.remove() (via Unit.remove_status()) the same
## way ApplyStatusEffect bridges to StatusManager.apply() — nothing about
## Ability/UnitCombat needed to change for this to exist, it's just
## another AbilityEffect slotting into the usual effects array.
##
## Silently does nothing if target doesn't actually have this status
## active (StatusManager.remove() already no-ops in that case) — cast a
## Cure on someone who isn't afflicted and it just resolves as an
## anticlimactic no-op, same as attacking someone already at 0 HP would
## be nonsensical rather than crashing.

@export var status: StatusEffect


func apply(_attacker: Unit, target, _ability: Ability) -> Dictionary:
	if not target is Unit or not status:
		return {}

	var was_active: bool = target.has_status(status)
	target.remove_status(status)

	return {"removed_status": status.status_name, "was_active": was_active}


func describe() -> String:
	return "Removes %s" % (status.status_name if status else "(no status set)")
