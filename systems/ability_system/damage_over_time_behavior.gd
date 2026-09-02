class_name DamageOverTimeBehavior
extends StatusBehavior
## Deals dice-rolled damage at the start of each of the owner's turns
## while active — Bleeding, Burning, Poison, etc. are all the SAME
## reusable behavior, just wrapped in different StatusEffect resources
## for name/icon/duration, exactly like DamageEffect being reused across
## different Ability resources rather than needing a subclass per
## damage source.

@export var dice_count: int = 1
@export var dice_sides: int = 6
@export var dice_bonus: int = 0
## Whether this bypasses damage_reduction entirely (bleeding/poison
## often ignores armor in many systems) or is mitigated the same as
## ordinary combat damage — your call per status.
@export var ignores_damage_reduction: bool = true


func on_turn_start(unit: Unit, active: ActiveStatus) -> void:
	var raw: int = 0
	for _i in active.stacks:
		raw += roll_damage()

	var applied: int = raw if ignores_damage_reduction else max(raw - unit.get_stat("DR"), 0)
	unit.take_damage(applied)


func roll_damage() -> int:
	var total: int = 0
	for _i in dice_count:
		total += randi_range(1, dice_sides)
	return total + dice_bonus


func describe() -> String:
	return "%dd%d+%d damage per turn" % [dice_count, dice_sides, dice_bonus]
