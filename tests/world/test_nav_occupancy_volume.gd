extends AiTestCase
## Units occupy their whole body height, and a goal sealed off by them
## fails fast.
##
## A goal ringed by standing units is in the same region as the walker
## (regions ignore units), so only the search can find it sealed. It used
## to find out by exhausting a corridor search and then an unrestricted one
## to the expansion cap (~200 ms); the goal-side flood empties the ring's
## pocket in a few hundred expansions instead.
##
## A flier at chest height used to fly straight through a standing unit,
## whose occupancy was a disc at its feet layer only.

const RING_RADIUS := 1.6
const RING_COUNT := 12
const STANDER := Vector3(0.0, 0.0, 8.0)
const FLIGHT_Y := 1.2


func run() -> void:
	var walker: Unit = spawn_brute(-10.0, 0.0)
	for i in RING_COUNT:
		var a: float = TAU * i / RING_COUNT
		spawn_brute(cos(a) * RING_RADIUS, sin(a) * RING_RADIUS)
	var stander: Unit = spawn_brute(STANDER.x, STANDER.z)
	var flier: Unit = spawn_brute(-20.0, 20.0)

	# Warm the bakes along the walker's way, so the timed call measures
	# the search and not the first rasterisation.
	NavigationGrid.find_path(get_tree(), walker.global_position, Vector3(0.0, 0.0, 4.0), walker, false)
	var t0: int = Time.get_ticks_usec()
	var ringed: PackedVector3Array = NavigationGrid.find_path(get_tree(), walker.global_position, Vector3.ZERO, walker, false)
	var ringed_ms: float = (Time.get_ticks_usec() - t0) / 1000.0

	var from := Vector3(STANDER.x - 4.0, FLIGHT_Y, STANDER.z)
	var to := Vector3(STANDER.x + 4.0, FLIGHT_Y, STANDER.z)
	var flown: PackedVector3Array = NavigationGrid.find_path(get_tree(), from, to, flier, true)
	var top: float = STANDER.y + stander.height - 0.05
	var through: Array = _samples(flown).filter(func(p: Vector3) -> bool:
		return Vector2(p.x - STANDER.x, p.z - STANDER.z).length() < 0.6 and p.y < top)

	check("a ringed goal fails fast, and a flier goes around or over a standing unit",
		ringed.is_empty() and ringed_ms < 20.0 and flown.size() >= 2 and through.is_empty(),
		"ringed %d pts in %.1f ms; flier path %s crosses the body at %s" % [ringed.size(), ringed_ms, flown, through])


## Points every 0.1 m along the path, so a straight segment through the
## standing unit shows up even with no waypoint inside it.
func _samples(path: PackedVector3Array) -> Array:
	var out: Array = []
	for i in path.size() - 1:
		var steps: int = maxi(1, ceili(path[i].distance_to(path[i + 1]) / 0.1))
		for k in steps + 1:
			out.append(path[i].lerp(path[i + 1], float(k) / steps))
	return out
