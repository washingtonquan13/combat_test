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

@export var status: StatusEffect
@export var affects_hostiles: bool = true
@export var affects_allies: bool = false


func apply(attacker: Unit, target, ability: Ability) -> Dictionary:
	if not target is Vector3 or not status:
		return {}

	var targeting := ability.targeting as AreaTargeting
	if not targeting:
		return {}

	var center: Vector3 = target
	var radius: float = targeting.radius
	var affected: Array[Unit] = []

	for node in attacker.get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if not unit or not unit.is_alive():
			continue

		var edge_dist: float = center.distance_to(unit.global_position) - unit.radius
		if edge_dist > radius:
			continue

		var is_hostile: bool = attacker.is_hostile_to(unit)
		if is_hostile and not affects_hostiles:
			continue
		if not is_hostile and not affects_allies:
			continue

		unit.apply_status(status)
		affected.append(unit)

	return {"affected_with_status": affected}


func describe() -> String:
	return "Applies %s" % (status.status_name if status else "(no status set)")
