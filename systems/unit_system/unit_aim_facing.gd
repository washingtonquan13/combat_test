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
## frame would just fight each other — which is why the acting unit
## (Aim.caster, from ClickRouter.active_unit) being a commandable one
## matters here and not only for visual indicators.
##
## Extends IndicatorBase for the live/draw contract with ClickRouter (this
## has no visuals of its own, so _create_line_mesh() goes unused): it is
## handed the same Aim the indicators draw from — the hovered unit first,
## the ground point as fallback — rather than raycasting for itself.
##
## The Aim comes once per render frame but the turn is applied on every
## physics tick, like all facing, so a turn takes the same time at any frame
## rate. Below the physics rate several ticks share one Aim, so the point is
## kept between draws rather than used up.

var _unit: Unit = null
var _aim_point: Vector3 = Vector3.ZERO


func serves() -> StringName:
	return &"aim_facing"


func set_live(live: bool) -> void:
	super(live)
	if not live:
		_unit = null


func draw(aim: Aim) -> void:
	var hovered: Unit = aim.cursor.unit if aim.cursor else null
	var aim_point = hovered.global_position if hovered else aim.point
	_unit = aim.caster if aim_point != null else null
	if _unit:
		_aim_point = aim_point


func _physics_process(delta: float) -> void:
	if is_instance_valid(_unit):
		_unit.face_point(_aim_point, delta)
