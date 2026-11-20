class_name LocomotionDriver
extends RefCounted
## What UnitAnimator, UnitMovement and UnitFacing ask of a humanoid body's
## locomotion, whichever drives it: UnitLocomotion (starts, stops, turns in
## place, the walk) or SimpleLocomotion (idle and run only). LocomotionSet's
## `simple` picks; UnitAnimator makes it.
##
## Owned by the unit system (docs/systems/unit.md, "Locomotion"). Every
## method here is a no-op: a driver overrides what it does.

## Held (ClickRouter's hold-to-move): the orders are steering, not
## destinations (ground_click_target.gd sets it while the button is down).
var held: bool = false:
	set(value):
		if value != held:
			held = value
			_held_changed()
## Where a move comes to rest, if not the set's idle: called with a blend,
## it plays the rest itself (a drawn weapon's guard) and returns true, or
## returns false for the set's idle (UnitAnimator sets it).
var rest: Callable
## The planted feet held to the ground (null when the driver pins none).
var foot_lock: BodyFootLock = null


func _held_changed() -> void:
	pass


## The idle the driver comes to rest in.
func idle_clip() -> String:
	return ""


## The turning loop that way (left for a positive rate), for turning on the
## spot; "" for none.
func turn_loop(_left: bool) -> String:
	return ""


## Whether a move is under way that this drives (UnitMovement asks travel()).
func drives() -> bool:
	return false


## Whether the unit is being carried onto its end exactly (UnitMovement
## arrives on the point itself then, not within its arrival tolerance).
func lands() -> bool:
	return false


## Whether the driver is turning the unit in place (UnitFacing keeps off it).
func turning() -> bool:
	return false


## A move is ordered: `route` metres, its first leg `first_leg`.
func begin(_route: float, _first_leg: Vector3) -> void:
	pass


## Standing, a swing of facing to `yaw`. Returns whether the driver turns
## the unit; if not, UnitFacing does.
func turn_to(_yaw: float) -> bool:
	return false


## How far along its route the unit goes this tick, `left` metres from its
## end. Called by UnitMovement on every grounded walking tick it drives.
func travel(_delta: float, _left: float) -> float:
	return 0.0


## A tick with no walk.
func tick(_delta: float) -> void:
	pass


## The move is over. Returns whether this shows what comes next.
func finish() -> bool:
	return false


## Something else takes the body (a stance, a cast, a cutscene, a climb).
func abandon() -> void:
	pass


## A tick while the body is not locomotion's: it lets go of the body.
func relax(_delta: float) -> void:
	pass
