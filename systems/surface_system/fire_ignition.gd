extends RefCounted
## How a fire catches, shared by Fire (fire_surface.gd) and Wall of Fire
## (fire_wall.gd): over its first seconds each column of flame starts as
## a low lick at its foot, shoots up past its full height and settles,
## burning hot and white as it catches and cooling to its own colours.
## s is how far through catching a column is, 0..1.

## How tall a column of flame stands, as a share of its full height.
static func height(s: float) -> float:
	var t: float = clampf(s, 0.0, 1.0) - 1.0
	const OVERSHOOT := 2.4
	return 0.2 + 0.8 * (1.0 + (OVERSHOOT + 1.0) * t * t * t + OVERSHOOT * t * t)


## How hot the flame burns over its own heat: 1 as it catches, gone by s = 1.
static func flash(s: float) -> float:
	var k: float = 1.0 - clampf(s, 0.0, 1.0)
	return k * k
