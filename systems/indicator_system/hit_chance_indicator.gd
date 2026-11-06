extends IndicatorBase
## The chance to hit, beside the cursor, while it is over a unit the
## acting unit's click would attack — the armed ability, or the default
## attack when nothing is armed (the same Unit.click_ability_for the click
## itself uses). Unit.hit_chance gives the number: the to-hit roll and the
## defender's Dodge, as exact odds, so this reads what the roll will
## actually do. A status the target can resist (StatusEffect.
## resisted_by) adds its own line, the chance it ends up on the target —
## so a Sleep that never rolls to hit still shows its odds. Hidden when
## neither applies, since it always lands.
##
## The label is authored in the scene (MainRoot's TacticalUI/
## HitChanceLabel) so its font and style are edited there; this only sets
## its text and moves it to the cursor.

@export var label: Label
@export var cursor_offset: Vector2 = Vector2(18, 18)


func serves() -> StringName:
	return &"hit_chance"


func _ready() -> void:
	super()
	if label:
		label.visible = false


func hide_visuals() -> void:
	super()
	if label:
		label.visible = false


func is_showing_anything() -> bool:
	return super() or (label != null and label.visible)


func draw(aim: Aim) -> void:
	if label == null:
		return
	var text: String = _readout_under_cursor(aim)
	label.visible = text != ""
	if label.visible:
		label.text = text
		label.position = get_viewport().get_mouse_position() + cursor_offset


## Empty when the cursor is not over something a click would use a
## rolled ability on.
func _readout_under_cursor(aim: Aim) -> String:
	var acting: Unit = aim.caster
	if acting == null:
		return ""
	var hovered: Unit = aim.cursor.unit if aim.cursor else null
	if hovered == null or hovered == acting or not hovered.is_alive():
		return ""
	var ability: Ability = hovered.click_ability_for(acting)
	if ability == null:
		return ""
	var hit: float = acting.hit_chance(hovered, ability)
	var lines: PackedStringArray = []
	if ability.requires_to_hit:
		lines.append(_percent(hit) + _aim_suffix(acting, ability))
	for effect in ability.effects:
		var status: StatusEffect = effect.status if effect is ApplyStatusEffect else null
		if status and status.resisted_by != &"":
			lines.append("%s %s" % [status.status_name, _percent(hit * hovered.status_land_chance(status, acting))])
	return "
".join(lines)


## " vitals" when the attack goes where it is aimed, " torso" when an aim
## is on but this attack can't take it there, nothing when not aiming.
func _aim_suffix(acting: Unit, ability: Ability) -> String:
	if acting.aim() == null:
		return ""
	var location: HitLocation = acting.hit_location_for(ability)
	return " " + (location.display_name.to_lower() if location else "torso")


func _percent(chance: float) -> String:
	return "%d%%" % roundi(chance * 100.0)
