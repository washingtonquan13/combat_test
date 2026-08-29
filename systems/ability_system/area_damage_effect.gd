class_name AreaDamageEffect
extends AbilityEffect
## Deals dice-rolled damage to every unit within radius of a ground
## point — target here is a Vector3 (an AoE center), not a single Unit,
## pairing with AreaTargeting the same way MoveCasterEffect pairs with
## GroundPointTargeting. Rolls its own damage dice per affected unit,
## same sibling-class pattern as DamageEffect/StDamageEffect rather than
## trying to share dice fields across effect types.
##
## radius is NOT set here — it's read from ability.targeting.radius (see
## AreaTargeting), the single source of truth shared with any other
## area-based effect on the same ability (AreaApplyStatusEffect, etc.),
## so a status and the damage that triggers it structurally cannot
## disagree about how big the blast is.
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
##
## The scan itself (edge-distance + hostile/ally gating) lives in
## UnitQuery.area_affected — AreaHealEffect/AreaApplyStatusEffect share
## the exact same scan; only what happens to each matched unit differs.

@export var dice_count: int = 2
@export var dice_sides: int = 6
@export var dice_bonus: int = 0
@export var affects_hostiles: bool = true
@export var affects_allies: bool = false


func apply(attacker: Unit, target, ability: Ability, _is_critical: bool) -> Dictionary:
	if not target is Vector3:
		return {}

	var targeting := ability.targeting as AreaTargeting
	if not targeting:
		return {}

	var center: Vector3 = target
	var radius: float = targeting.radius
	var affected: Array = []

	for unit in UnitQuery.area_affected(attacker.get_tree(), attacker, center, radius, affects_hostiles, affects_allies):
		var raw_damage: int = roll_damage()
		var applied: int = max(raw_damage - unit.get_stat("DR"), 0)
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
	return "%dd%d+%d damage" % [dice_count, dice_sides, dice_bonus]


## Per-target average, NOT scaled by how many units the blast would
## actually catch — AiScorer scores one (ability, target) candidate at a
## time (see that file's own header on why multi-target AoE candidate
## generation is out of scope for this pass), so this answers "how much
## would ONE hit unit expect to take," same shape as every sibling
## damage effect's expected_damage().
func expected_damage(_attacker: Unit) -> float:
	return float(dice_count) * (float(dice_sides) + 1.0) / 2.0 + float(dice_bonus)
