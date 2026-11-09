class_name SuperJumpBehavior
extends StatusBehavior
## Jumps go further, and a fall that wouldn't outdo the jump doesn't count.

## How many times over one level multiplies a jump. Each level multiplies
## again: 2, 4, 8.
@export var distance_multiplier: float = 2.0
## Metres of any fall ignored at one level. Grows with the jump.
@export var ignored_fall: float = 3.0


func at_level(level: int) -> StatusBehavior:
	if level == 1:
		return self
	var scaled: SuperJumpBehavior = duplicate()
	scaled.distance_multiplier = pow(distance_multiplier, level)
	scaled.ignored_fall = ignored_fall * pow(distance_multiplier, level - 1)
	return scaled


func jump_distance_multiplier() -> float:
	return distance_multiplier


func ignored_fall_distance() -> float:
	return ignored_fall


func describe() -> String:
	return "Jump x%s, ignores %s m of a fall" % [String.num(distance_multiplier), String.num(ignored_fall)]
