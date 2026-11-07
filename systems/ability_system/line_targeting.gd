class_name LineTargeting
extends AbilityTargeting
## Targets a line, placed with two clicks — the first sets
## where it starts, the second where it ends (Wall of Fire). target is a
## LineTarget. Both ends must be within max_range of the caster and, with
## requires_line_of_sight, in sight; the line is never longer than
## max_length (the second click is pulled in to it, so the preview and
## the cast agree). Each end may be Ctrl-dragged into the air like an
## aerial blast (resolve_target_point): the wall then stands from that
## height and lays no ground fire under it.
##
## The first click is held in AbilityManager (line_start) between the two
## clicks, the same place a Ctrl-dragged aim height waits, and is dropped
## when the ability is disarmed.

@export var max_range: float = 18.0
@export var max_length: float = 12.0
@export var requires_line_of_sight: bool = true
@export var los_obstruction_mask: int = 1


func is_valid_target(attacker: Unit, target) -> bool:
	return check(attacker, target) == Reach.OK


## A line is as reachable as its first unreachable end. Too long is
## INVALID rather than out of range: end_for() never builds one, so only
## a hand-made LineTarget can be.
func check(attacker: Unit, target) -> Reach:
	if not target is LineTarget:
		return Reach.INVALID
	var line: LineTarget = target
	if _flat(line.to - line.from).length() > max_length + 0.01:
		return Reach.INVALID
	var from_reach: Reach = check_point(attacker, line.from)
	if from_reach != Reach.OK:
		return from_reach
	return check_point(attacker, line.to)


## Whether one end of the line may go at point.
func can_reach(attacker: Unit, point: Vector3) -> bool:
	return check_point(attacker, point) == Reach.OK


## Range and line of sight to one end of the line: the rule both clicks
## and the preview share.
func check_point(attacker: Unit, point: Vector3) -> Reach:
	if attacker.global_position.distance_to(point) > max_range:
		return Reach.OUT_OF_RANGE
	if requires_line_of_sight and not LineOfSight.has_clear_shot_to_point(attacker, point, los_obstruction_mask):
		return Reach.BLOCKED
	return Reach.OK


## Where a line started at start ends when aimed at point: point, pulled
## in to max_length.
func end_for(start: Vector3, point: Vector3) -> Vector3:
	var end: Vector3 = start + _flat(point - start).limit_length(max_length)
	end.y = point.y
	return end


## First click: holds the start, if one may go there. Second: the line,
## if it is a legal one — an illegal end keeps the start for another try.
func resolve_click(attacker: Unit, click_position: Vector3) -> Variant:
	click_position = resolve_target_point(click_position)
	if not AbilityManager.has_line_start:
		if can_reach(attacker, click_position):
			AbilityManager.set_line_start(click_position)
		return null
	var start: Vector3 = AbilityManager.line_start
	var line := LineTarget.new(start, end_for(start, click_position))
	if not is_valid_target(attacker, line):
		return null
	AbilityManager.clear_line_start()
	return line


## Mirrors resolve_click's two steps: the first click only needs its end
## reachable; the second is judged as the whole line it would make.
func check_click(attacker: Unit, click_position: Vector3) -> Reach:
	var point: Vector3 = resolve_target_point(click_position)
	if not AbilityManager.has_line_start:
		return check_point(attacker, point)
	var start: Vector3 = AbilityManager.line_start
	return check(attacker, LineTarget.new(start, end_for(start, point)))


func expects_point_target() -> bool:
	return true


func approach_range() -> float:
	return max_range


func indicator_ids() -> Array[StringName]:
	return [&"line"]


func describe() -> String:
	var s := "Line target, range %.1f, up to %.1f long" % [max_range, max_length]
	if requires_line_of_sight:
		s += ", requires line of sight"
	return s


## Lifts a click to the Ctrl-dragged aim height, if any - the same
## value line_indicator.gd previews.
func resolve_target_point(click_position: Vector3) -> Vector3:
	if AbilityManager.has_aim_height_override:
		click_position.y = AbilityManager.aim_height_override
	return click_position


func takes_aim_height() -> bool:
	return true


static func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)
