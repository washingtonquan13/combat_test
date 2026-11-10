class_name ArcFlight
extends RefCounted
## A unit flying from one point to another along a parabola: Jump (the
## jumper flies) and Shove (the one shoved flies). One place for the curve
## and the flight, so checks along the path (walls, a fall at the end)
## get added once for both.
##
## Bypasses move_and_slide() and path-finding on purpose: a flight goes
## over what a walk would have to go around, but not through a wall:
## clear_fraction() says how far along the curve it gets. A jump whose
## curve hits something can't be aimed there; a shove stops short and
## drops. Landing more than SAFE_FALL below the take-off hurts.

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


## Where the flight is at t (0 = from, 1 = to): a parabola peaking height
## above the HIGHER end. On the flat that is height above the line at t
## 0.5; off a ledge it rises before it drops, so it clears the edge it
## leaves (over the straight line it would dip into it), and up onto one
## it clears the edge it lands on. Height 0 going down is a plain fall: it
## starts with no upward speed and gains it, which is a drop off a ceiling.
static func point(from: Vector3, to: Vector3, height: float, t: float) -> Vector3:
	var p: Vector3 = from.lerp(to, t)
	var rise: float = maxf(from.y, to.y) + maxf(height, 0.0) - from.y
	var drop: float = to.y - from.y
	var b: float = 2.0 * rise + 2.0 * sqrt(maxf(rise * (rise - drop), 0.0))
	p.y = from.y + b * t + (drop - b) * t * t
	return p


# --- How long a flight takes ------------------------------------------

## Ground covered per second in the air: a full ST 10 jump (4.5 m) takes
## 1.0 s, as Jump always did.
const FLIGHT_SPEED: float = 4.5

## No flight is quicker than this, so a short hop still reads as a hop.
const MIN_FLIGHT_TIME: float = 0.4

## For a flight that drops: it can't come down faster than a fall from
## that height would (sqrt(2 x drop / g)), so going off a ledge takes as
## long as the drop, not as long as the few metres across.
const GRAVITY: float = 9.8


## Seconds a flight from `from` to `to` takes: the ground it covers at
## FLIGHT_SPEED, at least MIN_FLIGHT_TIME, and at least the fall time of
## any drop. Jump and Shove both fly this long, so a short shove into a
## wall no longer hangs in the air as long as a full jump.
static func duration(from: Vector3, to: Vector3) -> float:
	var across: float = Vector2(from.x, from.z).distance_to(Vector2(to.x, to.z))
	var drop: float = maxf(from.y - to.y, 0.0)
	return maxf(maxf(across / FLIGHT_SPEED, MIN_FLIGHT_TIME), sqrt(2.0 * drop / GRAVITY))


## Flies unit from where it is to `to`, for duration(). The unit is busy
## until it lands, and landing well below where it took off hurts
## (take_fall). Doesn't check the way is clear: callers pick a `to` that
## is (clear_fraction).
static func fly(unit: Unit, to: Vector3, height: float) -> Tween:
	var from: Vector3 = unit.global_position
	unit.begin_busy()
	var tween: Tween = unit.carry_tween()
	tween.tween_method(
		func(t: float): unit.global_position = point(from, to, height, t),
		0.0, 1.0, duration(from, to)
	)
	tween.tween_callback(func() -> void:
		take_fall(unit, from.y - to.y)
		unit.end_busy())
	return tween


# --- Walls on the way -------------------------------------------------

## How many straight pieces the curve is checked in.
const PATH_SAMPLES: int = 16

## The checked body is a sphere of the unit's radius with its bottom this
## far above the line the feet follow, so the floor it takes off from and
## lands on doesn't count as in the way.
const PATH_LIFT: float = 0.2

## What a flight can hit: the ground layer (level geometry, props) and a
## solid cloud's barrier (SurfaceManager.BARRIER_LAYER, 1 << 18: a frozen
## Wall of Water stops a jump or a shove like rock). Units on it are left
## out (see clear_fraction).
const PATH_MASK: int = 1 | (1 << 18)


## How far along the flight from `from` to `to` unit gets before something
## is in the way: 1.0 when the whole curve is clear, else the t (0..1)
## where it hits. Units don't count: a jump goes over them, and a shove's
## landing is already kept off them.
##
## The lift keeps the body clear of what it stands on, so leaving a wall or
## a ceiling it starts out along that surface's normal and comes round to
## up by the landing. A curve that goes into the wall still hits it.
static func clear_fraction(unit: Unit, from: Vector3, to: Vector3, height: float) -> float:
	var space: PhysicsDirectSpaceState3D = unit.get_world_3d().direct_space_state
	var sphere := SphereShape3D.new()
	sphere.radius = unit.radius
	var lift := Vector3(0, unit.radius + PATH_LIFT, 0)
	var first_lift: Vector3 = lift
	if from.is_equal_approx(unit.global_position):
		var held: Vector3 = unit.held_surface_normal()
		if held != Vector3.ZERO:
			first_lift = held * lift.y
	var exclude: Array[RID] = []
	for other in unit.get_tree().get_nodes_in_group("units"):
		if other is CollisionObject3D:
			exclude.append(other.get_rid())
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.collision_mask = PATH_MASK
	query.exclude = exclude
	for i in PATH_SAMPLES:
		var t0: float = float(i) / PATH_SAMPLES
		var t1: float = float(i + 1) / PATH_SAMPLES
		var a: Vector3 = point(from, to, height, t0) + first_lift.lerp(lift, t0)
		var b: Vector3 = point(from, to, height, t1) + first_lift.lerp(lift, t1)
		query.transform = Transform3D(Basis(), a)
		query.motion = b - a
		# A clear sweep is [1.0, 1.0], not empty.
		var hit: PackedFloat32Array = space.cast_motion(query)
		if hit.size() == 2 and hit[0] < 1.0:
			return t0 + hit[0] * (t1 - t0)
	return 1.0


# --- Falling ----------------------------------------------------------

## Landing less than this far below the take-off doesn't hurt (BG3's 4 m),
## so hopping off a crate stays free.
const SAFE_FALL: float = 4.0

const METRES_PER_YARD: float = 0.9144


## Damage dice for a fall of drop metres (GURPS B431): velocity in yd/s is
## sqrt(21.4 x yards fallen), and the dice are HP x velocity / 100, at
## least 1. 0 within SAFE_FALL.
static func fall_dice(hp: float, drop: float) -> int:
	if drop < SAFE_FALL:
		return 0
	var velocity: float = sqrt(21.4 * drop / METRES_PER_YARD)
	return maxi(roundi(hp * velocity / 100.0), 1)


## Crushing damage to unit for landing drop metres below where it took
## off: rolled, then through DR like any hit. Returns the injury.
static func take_fall(unit: Unit, drop: float) -> int:
	if not is_instance_valid(unit) or unit.is_flying() or not unit.is_alive():
		return 0
	var dice: int = fall_dice(unit.get_stat(StatIds.HP), unit.counted_fall(drop))
	if dice <= 0:
		return 0
	var raw: int = 0
	for _i in dice:
		raw += randi_range(1, 6)
	raw = unit.soften_fall(raw)
	var injury: int = DamageResolver.injury(raw, unit, DamageResolver.WoundType.CRUSHING)
	SystemLog.print("%s falls %.1f m (%dd6: %d) and takes %d." % [LogFormat.unit_name(unit), drop, dice, raw, injury])
	unit.take_damage(injury)
	return injury
