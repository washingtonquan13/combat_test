class_name LogFormat
extends RefCounted
## Small BBCode-formatting helpers shared by anything that logs to
## SystemLog and wants consistent unit/damage/faction coloring, instead
## of every call site re-inventing its own color scheme or hardcoding
## hex values inline. Static values/functions — this is a shared
## formatting convention, not per-instance state.

static var player_color: Color = Color(0.4, 0.7, 1.0)
static var enemy_color: Color = Color(1.0, 0.4, 0.4)
static var damage_color: Color = Color(1.0, 0.6, 0.2)
static var heal_color: Color = Color(0.4, 1.0, 0.5)


static func unit_name(unit: Unit) -> String:
	var color: Color = player_color if unit.is_player_controlled() else enemy_color
	return "[color=#%s]%s[/color]" % [color.to_html(false), unit.get_display_name()]


static func faction_name(faction: StringName) -> String:
	var color: Color = player_color if faction == Unit.PLAYER_FACTION else enemy_color
	return "[color=#%s]%s[/color]" % [color.to_html(false), faction]


static func damage(amount: int) -> String:
	return "[color=#%s][b]%d[/b][/color]" % [damage_color.to_html(false), amount]


static func heal(amount: int) -> String:
	return "[color=#%s][b]%d[/b][/color]" % [heal_color.to_html(false), amount]
