class_name AreaDamageEffect
extends AbilityEffect
## Deals dice-rolled damage to every unit within radius of a ground
## point — target here is a Vector3 (an AoE center), not a single Unit,
## pairing with AreaTargeting the same way MoveCasterEffect pairs with
## GroundPointTargeting. Rolls its own damage dice per affected unit,
## same sibling-class pattern as DamageEffect/StDamageEffect rather than
## trying to share dice fields across effect types.
##
## Friendly-fire safe by default (affects_allies=false, affects_hostiles
## =true) — flip affects_allies on for something genuinely
## indiscriminate. "Ally"/"hostile" here is relative to the CASTER
## (attacker.is_hostile_to), not any fixed side.
##
## Distance check is edge-to-edge (unit.global_position minus their own
## radius), not center-to-center — a unit whose edge is inside the blast
## radius is caught by it, matching the edge-based convention used
## everywhere else in this project (reach, ranged max_range, etc.).

@export var radius: float = 3.0
@export var dice_count: int = 2
@export var dice_sides: int = 6
@export var dice_bonus: int = 0
@export var affects_hostiles: bool = true
@export var affects_allies: bool = false


func apply(attacker: Unit, target) -> Dictionary:
	if not target is Vector3:
		return {}

	var center: Vector3 = target
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

		var raw_damage: int = roll_damage()
		var applied: int = max(raw_damage - unit.damage_reduction, 0)
		unit.take_damage(applied)
		affected.append({"unit": unit, "raw_damage": raw_damage, "damage": applied})

	var total_damage: int = 0
	for entry in affected:
		total_damage += entry.damage

	return {"affected": affected, "damage": total_damage}


func roll_damage() -> int:
	var total: int = 0
	for _i in dice_count:
		total += randi_range(1, dice_sides)
	return total + dice_bonus


func describe() -> String:
	return "%dd%d+%d damage in %.1fm radius" % [dice_count, dice_sides, dice_bonus, radius]
