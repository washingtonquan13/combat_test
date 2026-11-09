class_name AimingIntent
extends PlayerIntent
## An ability is armed (see AbilityManager) and the next click is aiming
## it.
##
## Holds the Ability itself rather than a flag, so the router can tell
## "aiming Fireball" from "aiming Jump" when it decides whether the
## intent actually changed, and so indicator_ids() can ask the ability
## which overlays belong to it instead of five indicators each asking the
## same question about themselves.
##
## A click while armed only ever casts. A point/area ability lands at
## Cursor.aim_point - a hovered unit (its centre of mass for a shape
## aimed in 3D, else its feet), else the cursor's point - the same
## point the preview (Aim.point) showed. It used to go to the unit path
## when a unit was hovered, where the targeting check refused it
## silently after the preview had drawn it on the unit's capsule. A
## unit-targeted ability takes the hovered unit; clicked on bare ground
## it goes off at that spot if it may (AbilityTargeting.aims_at_ground),
## else does nothing (and the click is consumed) instead of falling
## through to a move order, so aiming never walks the caster anywhere.

func _init(armed: Ability) -> void:
	ability = armed


func kind() -> StringName:
	return &"aiming"


## Point/area ability: cast at Cursor.aim_point (null - the ray missed -
## is not consumed). Otherwise a hovered unit is the target; a hovered
## interactable is left to its own handler; a ground-aimable attack hits
## the ground clicked; and any other click on nothing is consumed and
## does nothing - it must not select or move.
func handle_left_click(router, cursor: Cursor) -> bool:
	if ability and ability.targeting and ability.targeting.expects_point_target():
		var p = cursor.aim_point(ability)
		if p == null:
			return false
		return router.use_ground_targeted(ability, p)
	if cursor.unit:
		return router.click_unit(cursor.unit, true)
	if cursor.interactable:
		return false
	# A unit-targeted attack that may go off at the ground (AbilityTargeting.
	# aims_at_ground) hits the spot clicked.
	if ability and ability.targeting and ability.targeting.aims_at_ground and cursor.ground != null:
		return router.use_ground_targeted(ability, cursor.ground)
	return true


## Cancelling what you just armed. Right-click has to swallow this even
## though nothing visible happens beyond the disarm — a right-click that
## silently opened a context menu for the unit you were about to shoot
## reads as broken.
func handle_right_click(_router, _cursor: Cursor) -> bool:
	AbilityManager.disarm()
	return true


## Shapes that may be aimed into the air (AbilityTargeting.
## takes_aim_height - Wall of Fire, the aerial clouds, cones, lines)
## take a height plane.
func drags_height(_router) -> bool:
	return ability != null and ability.targeting != null and ability.targeting.takes_aim_height()


## A flight whose curve the player may set (AbilityTargeting.takes_arc_height).
func drags_arc(_router) -> bool:
	return ability != null and ability.targeting != null and ability.targeting.takes_arc_height() \
			and is_instance_valid(AbilityManager.armed_unit)


func arc_height_at(point: Vector3) -> float:
	var unit: Unit = AbilityManager.armed_unit
	return ability.targeting.chosen_arc(unit, ability.targeting.landing_for(unit, point))


func clamp_arc(point: Vector3, height: float) -> float:
	var unit: Unit = AbilityManager.armed_unit
	return ability.targeting.clamp_arc(unit, ability.targeting.landing_for(unit, point), height)


func set_arc_height(point: Vector3, height: float) -> void:
	AbilityManager.set_arc_height_override(clamp_arc(point, height))


## The one rule for the aim height, from the cursor alone, so the preview
## (Aim.point) and the click (AbilityTargeting.resolve_target_point) read
## the same answer - the router calls this each frame and again with a
## click's own cursor before answering it. When the aim point is already
## a full 3D point - a plane point (a latched height, a Ctrl hold) or a
## hovered unit's centre of mass (Cursor.aim_point) - its own Y is the
## aim height, so nothing lifts it again (ConeTargeting.AIM_LIFT). A
## plain surface point clears it, and the shape aims the way it does with
## no height at all.
func steer(_router, cursor: Cursor) -> void:
	if not drags_height(_router):
		return
	var p = cursor.aim_point(ability)
	if p != null and (cursor.on_plane or cursor.aims_at_unit(ability)):
		AbilityManager.set_aim_height_override(p.y)
	else:
		AbilityManager.clear_aim_height_override()


## Whatever the ability itself says (see Ability.indicator_ids), plus the
## facing overlay and the hit-chance readout, which follow any armed
## ability regardless of shape.
## No movement preview: a click while armed casts rather than walks.
func indicator_ids() -> Array[StringName]:
	var ids: Array[StringName] = [&"aim_facing", &"hit_chance"]
	if ability:
		ids.append_array(ability.indicator_ids())
	return ids


func describe() -> String:
	return "aiming %s" % (ability.ability_name if ability else "nothing")
