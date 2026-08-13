class_name LandEffect
extends AbilityEffect
## Removes attacker's flying_status — the actual repositioning onto the
## ground is ForceLandOnExpireBehavior's job (attached to the status
## itself, see statuses/flying.tres), fired via on_remove the instant
## remove_status() below takes it off, so this effect doesn't duplicate
## that logic; it only decides WHETHER to remove it.

@export var flying_status: StatusEffect


func apply(attacker: Unit, _target, _ability: Ability, _is_critical: bool) -> Dictionary:
	if not flying_status:
		return {}
	if not attacker.has_status(flying_status):
		SystemLog.print("%s isn't flying." % LogFormat.unit_name(attacker))
		return {}

	attacker.remove_status(flying_status)
	return {}


func describe() -> String:
	return "Lands"
