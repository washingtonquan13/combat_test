class_name ArcFlight
extends RefCounted
## A unit flying from one point to another along a parabola: Jump (the
## jumper flies) and Shove (the one shoved flies). One place for the curve
## and the flight, so checks along the path (walls, a fall at the end)
## get added once for both.
##
## Bypasses move_and_slide() and path-finding on purpose: a flight goes
## over what a walk would have to go around.

## How far ST sends a body, in metres.
enum StrengthRule {
	## 5e's running long jump, ST in feet at 5e's 5 ft = 1.5 m (so 1 ft
	## = 0.3 m), plus BG3's 1.5 m: 0.3 x ST + 1.5. 4.5 m at ST 10.
	ROUNDED,
	## BG3's own numbers converted exactly: 4.5 m at ST 10, +1 m per 2
	## ST: 0.5 x ST - 0.5. Same at ST 10, steeper either side.
	EXACT,
}


static func strength_distance(st: float, rule: StrengthRule = StrengthRule.ROUNDED) -> float:
	match rule:
		StrengthRule.EXACT:
			return maxf(0.5 * st - 0.5, 0.0)
		_:
			return 0.3 * st + 1.5


## Where the flight is at t (0 = from, 1 = to): height above the straight
## line at t 0.5.
static func point(from: Vector3, to: Vector3, height: float, t: float) -> Vector3:
	var p: Vector3 = from.lerp(to, t)
	p.y += height * 4.0 * t * (1.0 - t)
	return p


## Flies unit from where it is to `to` over duration seconds. The unit is
## busy until it lands.
static func fly(unit: Unit, to: Vector3, height: float, duration: float) -> Tween:
	var from: Vector3 = unit.global_position
	unit.begin_busy()
	var tween: Tween = unit.create_tween()
	tween.tween_method(
		func(t: float): unit.global_position = point(from, to, height, t),
		0.0, 1.0, duration
	)
	tween.finished.connect(unit.end_busy)
	return tween
