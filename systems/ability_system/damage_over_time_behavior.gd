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
## GURPS damage type (B379): what DR lets through is multiplied by its
## wounding multiplier.
@export var wound_type: DamageResolver.WoundType = DamageResolver.WoundType.CRUSHING
## GURPS armor divisor (B378): the target's DR is divided by it. 1 is
## none; (2), (3), (5), (10) penetrate; (0.5), (0.2), (0.1) are stopped
## more easily than usual.
@export var armor_divisor: float = 1.0
## Whether this bypasses DR entirely (bleeding/poison
## often ignores armor in many systems) or is mitigated the same as
## ordinary combat damage — your call per status.
@export var ignores_damage_reduction: bool = true


func on_turn_start(unit: Unit, active: ActiveStatus) -> void:
	var raw: int = 0
	for _i in active.stacks:
		raw += roll_damage()

	var applied: int = DamageResolver.injury(raw, unit, wound_type, armor_divisor, false, ignores_damage_reduction)
	unit.take_damage(applied)


## Walking into the fire burns at once, one roll, as well as setting
## the status ticking.
func on_contact(unit: Unit, _active: ActiveStatus) -> void:
	unit.take_damage(DamageResolver.injury(roll_damage(), unit, wound_type, armor_divisor, false, ignores_damage_reduction))


func roll_damage() -> int:
	var total: int = 0
	for _i in dice_count:
		total += randi_range(1, dice_sides)
	return total + dice_bonus


func describe() -> String:
	return "%dd%d+%d %s damage per turn" % [dice_count, dice_sides, dice_bonus, DamageResolver.describe(wound_type, armor_divisor)]
