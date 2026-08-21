class_name AreaApplyStatusEffect
extends AbilityEffect
## Applies a status effect to every unit within radius of a ground point
## — the AoE counterpart to ApplyStatusEffect, the same way
## AreaDamageEffect is the AoE counterpart to DamageEffect. target here
## is a Vector3 (an AoE center), not a single Unit.
##
## radius is NOT set here — read from ability.targeting.radius (see
## AreaTargeting), the same single source of truth AreaDamageEffect
## reads from. Combine both on one ability (e.g. Fireball = [
## AreaDamageEffect, AreaApplyStatusEffect(status=Burning)]) and they're
## structurally guaranteed to affect the exact same area — no separate
## radius fields that could drift out of sync.
##
## Same shared scan as AreaDamageEffect — see that file's header — via
## UnitQuery.area_affected.

@export var status: StatusEffect
@export var affects_hostiles: bool = true
@export var affects_allies: bool = false


func apply(attacker: Unit, target, ability: Ability, _is_critical: bool) -> Dictionary:
	if not target is Vector3 or not status:
		return {}

	var targeting := ability.targeting as AreaTargeting
	if not targeting:
		return {}

	var center: Vector3 = target
	var radius: float = targeting.radius
	var affected: Array[Unit] = []

	for unit in UnitQuery.area_affected(attacker.get_tree(), attacker, center, radius, affects_hostiles, affects_allies):
		unit.apply_status(status)
		affected.append(unit)

	return {"affected_with_status": affected}


func describe() -> String:
	return "Applies %s" % (status.status_name if status else "(no status set)")
