extends IndicatorBase
## Smoothly rotates the current turn's player-controlled unit to face
## wherever they're currently aiming, while ANY ability is armed —
## melee, ranged, area, or ground-point/jump, all of them, since facing
## your intended direction is useful regardless of ability shape. Purely
## cosmetic — doesn't affect targeting/range/LoS logic at all, which is
## entirely unconcerned with which way the character model happens to
## be facing.
##
## Only checks whether SOMETHING is armed (via PlayerInteractionState.
## has_any_ability_armed), no fallback to the acting unit's own
## default_ability() — same deliberate choice as line_of_sight_indicator
## .gd: this only activates once something is explicitly armed via the
## hotbar, not on every ordinary click-to-attack.
##
## Extends IndicatorBase purely for its raycast helpers (this has no
## visuals of its own, so _create_line_mesh() goes unused) — same
## dual-raycast pattern (unit first, ground fallback) as
## line_of_sight_indicator.gd used, previously its own independent copy.


func _process(delta: float) -> void:
	var unit := _get_active_unit()
	if not unit:
		return

	var hovered := _get_hovered_unit()
	var aim_point = hovered.global_position if hovered else _get_mouse_ground_point()
	if aim_point == null:
		return

	unit.face_point(aim_point, delta)


## Delegates the shared "is the player currently free to act" condition
## to PlayerInteractionState, plus this script's own specific rule: only
## active while something's explicitly armed (movement-follow-path
## rotation, see Unit._physics_process, already owns facing while
## walking — both trying to set rotation.y in the same frame would just
## fight each other, which is part of why PlayerInteractionState's
## can_act() check matters here too, not just for visual indicators).
func _get_active_unit() -> Unit:
	if not PlayerInteractionState.has_any_ability_armed():
		return null
	return PlayerInteractionState.get_active_unit()
