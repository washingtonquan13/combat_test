class_name LineTargeting
extends AbilityTargeting
## Targets a line on the ground, placed with two clicks — the first sets
## where it starts, the second where it ends (Wall of Fire). target is a
## LineTarget. Both ends must be within max_range of the caster and, with
## requires_line_of_sight, in sight; the line is never longer than
## max_length (the second click is pulled in to it, so the preview and
## the cast agree).
##
## The first click is held in AbilityManager (line_start) between the two
## clicks, the same place a Ctrl-dragged aim height waits, and is dropped
## when the ability is disarmed.

@export var max_range: float = 18.0
@export var max_length: float = 12.0
@export var requires_line_of_sight: bool = true
@export var los_obstruction_mask: int = 1
@export var eye_height: float = 1.5


func is_valid_target(attacker: Unit, target) -> bool:
	if not target is LineTarget:
		return false
	var line: LineTarget = target
	if _flat(line.to - line.from).length() > max_length + 0.01:
		return false
	return can_reach(attacker, line.from) and can_reach(attacker, line.to)


## Whether one end of the line may go at point.
func can_reach(attacker: Unit, point: Vector3) -> bool:
	if attacker.global_position.distance_to(point) > max_range:
		return false
	if requires_line_of_sight and not LineOfSight.has_clear_shot_to_point(attacker, point, los_obstruction_mask, eye_height):
		return false
	return true


## Where a line started at start ends when aimed at point: point, pulled
## in to max_length.
func end_for(start: Vector3, point: Vector3) -> Vector3:
	var end: Vector3 = start + _flat(point - start).limit_length(max_length)
	end.y = point.y
	return end


## First click: holds the start, if one may go there. Second: the line,
## if it is a legal one — an illegal end keeps the start for another try.
func resolve_click(attacker: Unit, click_position: Vector3) -> Variant:
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


static func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)
