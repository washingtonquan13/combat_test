class_name HealOverTimeBehavior
extends StatusBehavior
## Restores dice-rolled HP at the start of each of the owner's turns
## while active — Regeneration, essentially — the positive-direction
## sibling of DamageOverTimeBehavior, kept separate for the same reason
## HealEffect is kept separate from DamageEffect rather than one class
## with a sign flag.

@export var dice_count: int = 1
@export var dice_sides: int = 6
@export var dice_bonus: int = 0


func on_turn_start(unit: Unit, active: ActiveStatus) -> void:
	var raw: int = 0
	for _i in active.stacks:
		raw += roll_heal()

	var applied: int = unit.heal(raw)

	if applied > 0:
		SystemLog.print("%s regenerates %s HP." % [LogFormat.unit_name(unit), LogFormat.heal(applied)])


func roll_heal() -> int:
	var total: int = 0
	for _i in dice_count:
		total += randi_range(1, dice_sides)
	return total + dice_bonus


func describe() -> String:
	return "%dd%d+%d healing per turn" % [dice_count, dice_sides, dice_bonus]
