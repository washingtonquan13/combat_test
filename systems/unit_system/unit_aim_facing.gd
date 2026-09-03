extends IndicatorBase
## Smoothly rotates the current turn's player-controlled unit to face
## wherever they're currently aiming, while ANY ability is armed —
## melee, ranged, area, or ground-point/jump, all of them, since facing
## your intended direction is useful regardless of ability shape. Purely
## cosmetic — doesn't affect targeting/range/LoS logic at all, which is
## entirely unconcerned with which way the character model happens to
## be facing.
##
## Live for as long as the intent is AimingIntent and no longer (see
## AimingIntent.indicator_ids, which names &"aim_facing" for every armed
## ability regardless of shape) — it does not ask whether something is
## armed, it is switched on when something is. No fallback to the acting
## unit's own default_ability() either: this only activates once
## something is explicitly armed via the hotbar, not on every ordinary
## click-to-attack.
##
## Movement-follow-path rotation (see Unit._physics_process) already owns
## facing while walking, and both trying to set rotation.y in the same
## frame would just fight each other — which is why _get_active_unit()'s
## can_act() half matters here and not only for visual indicators.
##
## Extends IndicatorBase purely for its raycast helpers (this has no
## visuals of its own, so _create_line_mesh() goes unused) — same
## dual-raycast pattern (unit first, ground fallback) as
## line_of_sight_indicator.gd used, previously its own independent copy.


func serves() -> StringName:
	return &"aim_facing"


func _process(delta: float) -> void:
	var unit := _get_active_unit()
	if not unit:
		return

	var hovered := _get_hovered_unit()
	var aim_point = hovered.global_position if hovered else _get_mouse_ground_point()
	if aim_point == null:
		return

	unit.face_point(aim_point, delta)
