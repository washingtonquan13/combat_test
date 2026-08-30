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
	CombatManager.turn_started.connect(_on_combat_changed)
	CombatManager.combat_ended.connect(_on_combat_changed)
	SelectionManager.selection_changed.connect(_on_selection_changed)
	pressed.connect(_on_pressed)
	visible = false


## The unit whose turn this button would end: the commanded one, if it
## is in a fight and the fight is waiting on it.
##
## Was driven by any relayed turn_started, which meant a turn beginning
## in ANY encounter toggled this button — including a fight in a world
## the player is not looking at, offering to end a turn belonging to
## somebody they cannot see.
func _acting_unit() -> Unit:
	for unit in SelectionManager.selected_units:
		if is_instance_valid(unit) and unit.in_combat() and unit.is_my_turn():
			return unit
	return null


func _refresh() -> void:
	visible = _acting_unit() != null


func _on_combat_changed(_arg) -> void:
	_refresh()


func _on_selection_changed(_selected_units: Array[Unit]) -> void:
	_refresh()


func _on_pressed() -> void:
	# That unit's own fight, not the focused encounter's — with a split
	# party those are not always the same one.
	var unit: Unit = _acting_unit()
	if unit:
		CombatManager.end_turn(unit)
