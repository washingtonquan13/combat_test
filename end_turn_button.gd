extends Button
## End Turn button — visible only during a player-controlled unit's own
## turn (hidden during AI turns and outside of combat, same visibility
## rule as movement_indicator.gd/ability_hotbar.gd).
##
## Just calls CombatManager.end_turn() on press — that function already
## handles deferring correctly if the current unit is still busy
## (mid-move, mid-ability-animation) rather than needing this button to
## know or care about that itself. Clicking while busy is safe: the
## request queues and applies once the unit becomes idle, it doesn't cut
## anything off.
##
## Scene setup: attach to a Button anywhere in your combat UI.

func _ready() -> void:
	CombatManager.turn_started.connect(_on_turn_started)
	CombatManager.combat_ended.connect(_on_combat_ended)
	pressed.connect(_on_pressed)
	visible = false


func _on_turn_started(unit: Unit) -> void:
	visible = unit.is_player_controlled()


func _on_combat_ended(_winning_faction: StringName) -> void:
	visible = false


func _on_pressed() -> void:
	CombatManager.end_turn()
