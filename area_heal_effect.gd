class_name AreaHealEffect
extends AbilityEffect
## AoE counterpart to HealEffect, same pairing AreaDamageEffect has with
## DamageEffect — target is a Vector3 (a heal-burst center), radius read
## from ability.targeting.radius (AreaTargeting), same single source of
## truth every other area effect in this project already uses.
##
## Defaults flipped from AreaDamageEffect's (affects_allies=true,
## affects_hostiles=false) — a heal indiscriminately hitting enemies too
## would need a very deliberate reason, unlike an explosion.

@export var dice_count: int = 2
@export var dice_sides: int = 6
@export var dice_bonus: int = 0
@export var affects_hostiles: bool = false
@export var affects_allies: bool = true


func apply(attacker: Unit, target, ability: Ability) -> Dictionary:
	if not target is Vector3:
		return {}

	var targeting := ability.targeting as AreaTargeting
	if not targeting:
		return {}

	var center: Vector3 = target
	var radius: float = targeting.radius
	var affected: Array = []

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

		var raw_heal: int = roll_heal()
		var before: int = unit.current_hp
		unit.current_hp = min(unit.current_hp + raw_heal, unit.maximum_hp)
		var applied: int = unit.current_hp - before
		affected.append({"unit": unit, "raw_heal": raw_heal, "healed": applied})

	var total_healed: int = 0
	for entry in affected:
		total_healed += entry.healed

	if total_healed > 0:
		SystemLog.print("%s's area heal restores %s HP." % [LogFormat.unit_name(attacker), LogFormat.heal(total_healed)])

	return {"affected": affected, "healed": total_healed}


func roll_heal() -> int:
	var total: int = 0
	for _i in dice_count:
		total += randi_range(1, dice_sides)
	return total + dice_bonus


func describe() -> String:
	return "%dd%d+%d healing (area)" % [dice_count, dice_sides, dice_bonus]
