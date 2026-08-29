class_name FlightRules
extends Resource
## Global, authored tuning for flight's cost side — altitude itself stays
## pure upside (no to-hit/defense penalty for being airborne, see
## AltitudeAdvantageBehavior), so every actual cost of flying lives here
## instead: climbing costs more movement than descending, and falling
## uncontrolled hurts. Same "one authored Resource, reached by a preload
## const" idiom UnitCombat.ALTITUDE_ADVANTAGE already uses for the exact
## same reason — a global combat rule that needs to be data, not a
## hardcoded constant, so it can be retuned without touching code.
##
## Consumed by RoutePlanner.plan() (the movement-cost multipliers) and
## Unit.land() (the fall-damage ladder) — see those files for how each
## half is actually used.

@export_group("Movement")
## Applied to a flying unit's UPWARD movement only — see RoutePlanner.plan(),
## which scales just the vertical component of each step before measuring
## distance. 1.0 restores today's plain-distance behavior; ground units
## are never touched by either multiplier regardless of value (flight-
## gated at the call site, not here).
@export var ascend_cost_multiplier: float = 2.0
@export var descend_cost_multiplier: float = 1.0

@export_group("Fall Damage")
## Descent at or below this many meters is a safe landing — no roll at
## all. Only reached on an UNCONTROLLED landing (status expiry cutting
## flight short); a voluntary Land action never rolls, regardless of
## height (see Unit.land()'s own controlled parameter).
@export var safe_fall_distance: float = 2.0
@export var fall_dice_sides: int = 6
## Flat bonus added per step past safe_fall_distance, resetting to 0
## every fall_steps_per_die steps (see dice_bonus_for_step() below) —
## together these two produce the agreed ladder: 1d, 1d+2, 1d+4, 2d,
## 2d+2, 2d+2+4, 3d... Set steps_per_die=4, adds_per_step=1 for a
## strict GURPS-style ladder instead; both are pure data.
@export var fall_adds_per_step: int = 2
@export var fall_steps_per_die: int = 3
## Whether a fall's damage is reduced by the target's own DR before
## take_damage() — mirrors DamageEffect.apply()'s own
## "raw roll minus DR, floored at 0" convention exactly, so falling
## composes with everything else that already expects that shape.
@export var fall_damage_reduced_by_dr: bool = true


## 0 if descent doesn't exceed safe_fall_distance — the "no damage on a
## safe drop" case. Otherwise the dice count/bonus for that fall,
## ready to roll and apply exactly like DamageEffect.roll_damage() does.
func fall_damage_for_descent(descent: float) -> Dictionary:
	var step: int = floori(descent - safe_fall_distance)
	if step <= 0:
		return {"dice_count": 0, "dice_bonus": 0}

	# step is 1-indexed here (step=1 is the first meter past safe), so
	# step-1 is what actually advances the die count / resets the bonus —
	# this is what keeps the ladder starting at exactly 1d, not 2d, on
	# the very first meter past safe_fall_distance.
	var zero_based: int = step - 1
	var dice_count: int = 1 + (zero_based / fall_steps_per_die)
	var dice_bonus: int = fall_adds_per_step * (zero_based % fall_steps_per_die)
	return {"dice_count": dice_count, "dice_bonus": dice_bonus}


## Rolls fall_damage_for_descent()'s result the same way
## DamageEffect.roll_damage() rolls dice_count/dice_sides/dice_bonus —
## same shape, so the two damage sources stay visually/mechanically
## consistent to a player reading combat log lines.
func roll_fall_damage(descent: float) -> int:
	var damage: Dictionary = fall_damage_for_descent(descent)
	var dice_count: int = damage["dice_count"]
	if dice_count <= 0:
		return 0

	var total: int = 0
	for _i in dice_count:
		total += randi_range(1, fall_dice_sides)
	return total + damage["dice_bonus"]
