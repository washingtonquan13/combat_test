extends Button
## One ability slot in the hotbar. A Button rather than a plain Control —
## gives click handling, an icon, and a disabled state for free instead
## of hand-building all three.
##
## Scene setup: just a Button sized to your icon dimensions. No child
## nodes needed — icon/text/tooltip are all set from code in _apply_ability.

@export var armed_modulate: Color = Color(1, 0.85, 0.2, 1)

var ability: Ability
var unit: Unit


func _ready() -> void:
	if ability:
		_apply_ability()


func _apply_ability() -> void:
	icon = ability.icon
	text = ability.ability_name if not ability.icon else ""
	tooltip_text = _build_tooltip()


func _build_tooltip() -> String:
	var lines: PackedStringArray = [ability.ability_name]

	if ability.targeting:
		lines.append(ability.targeting.describe())

	for effect in ability.effects:
		lines.append(effect.describe())

	return "\n".join(lines)


func set_armed(value: bool) -> void:
	modulate = armed_modulate if value else Color(1, 1, 1, 1)
