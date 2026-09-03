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


func handle_left_click(router, hit: ClickHit) -> bool:
	if hit.unit:
		return router.click_unit(hit.unit)
	if hit.interactable:
		return false
	if hit.ground == null:
		return false
	if router.use_ground_targeted(ability, hit.ground):
		return true
	return router.command_move(hit.ground)


## Cancelling what you just armed. Right-click has to swallow this even
## though nothing visible happens beyond the disarm — a right-click that
## silently opened a context menu for the unit you were about to shoot
## reads as broken.
func handle_right_click(_router, _hit: ClickHit) -> bool:
	AbilityManager.disarm()
	return true


## Whatever the ability itself says (see Ability.indicator_ids), plus the
## facing overlay, which follows any armed ability regardless of shape.
## No movement preview: a click while armed casts rather than walks.
func indicator_ids() -> Array[StringName]:
	var ids: Array[StringName] = [&"aim_facing"]
	if ability:
		ids.append_array(ability.indicator_ids())
	return ids


func describe() -> String:
	return "aiming %s" % (ability.ability_name if ability else "nothing")
