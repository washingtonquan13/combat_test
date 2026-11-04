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
## The click order deliberately matches what the old two-owner
## arrangement did, including the corner where an area ability is armed
## and the cursor is over a unit: that went to the unit path then (the
## router bailed on a hovered interactable and physics picking took it)
## and it goes to the unit path now. resolve_click_ability() prefers the
## armed ability, so the same cast is attempted and the same targeting
## check refuses it. Clicking bare ground with a UNIT-targeted ability
## armed likewise still falls through to a move order rather than doing
## nothing.

func _init(armed: Ability) -> void:
	ability = armed


func kind() -> StringName:
	return &"aiming"


func handle_left_click(router, cursor: Cursor) -> bool:
	if cursor.unit:
		return router.click_unit(cursor.unit)
	if cursor.interactable:
		return false
	if cursor.ground == null:
		return false
	if router.use_ground_targeted(ability, cursor.ground):
		return true
	return router.command_move(cursor.ground)


## Cancelling what you just armed. Right-click has to swallow this even
## though nothing visible happens beyond the disarm — a right-click that
## silently opened a context menu for the unit you were about to shoot
## reads as broken.
func handle_right_click(_router, _cursor: Cursor) -> bool:
	AbilityManager.disarm()
	return true


## Shapes that may be aimed into the air (AbilityTargeting.
## takes_aim_height - Wall of Fire, the aerial clouds) take the drag.
func drags_height(_router) -> bool:
	return ability != null and ability.targeting != null and ability.targeting.takes_aim_height()


## The drag's height becomes the aim height, which the preview (Aim.point)
## and the click (AbilityTargeting.resolve_target_point) both read - so
## the cast lands where the preview showed.
func steer(_router, cursor: Cursor) -> void:
	if cursor.dragging_height and cursor.height != null:
		AbilityManager.set_aim_height_override(cursor.height)


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
