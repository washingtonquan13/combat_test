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
	# AND when the world on screen changes, which is the subscription whose
	# absence produced the bug this file was written wrong for: travelling
	# away from a fight left this button on screen offering to end a turn
	# in a world the player could no longer see.
	#
	# The ordering is the trap, and it is why the world filter below was
	# not enough on its own. WorldManager._leave_focused() deselects
	# everybody BEFORE it stops pointing at the world being left, so the
	# selection_changed that fires there refreshes this button against the
	# OUTGOING context — which still contains the fighter whose turn it is.
	# visible latches true, focus moves, and the fight it refers to is
	# stalled waiting on that same absent player, so no turn_started or
	# combat_ended ever arrives to correct it. Only this signal does.
	#
	# initiative_row.gd:58 carries the same connection for the same reason.
	WorldManager.world_focused.connect(_on_world_focused)
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
	var context: WorldContext = WorldManager.context()

	# Same rule as the initiative row: a selection is an opinion, no
	# selection is no opinion. Travel clears the selection, so without the
	# fall-back a group that walked into a fight and got a turn had no way
	# to end it until the player clicked somebody.
	#
	# Scoped to the world ON SCREEN, exactly as initiative_row.gd:79-94
	# scopes the same read. This branch used to return before it ever
	# reached the context below, so anything that put a distant fighter
	# into the selection — debug_combat_harness.gd:113 re-selects the
	# acting unit from the unfiltered turn relay — showed the button for a
	# turn happening somewhere the player is not.
	var selected_here: bool = false
	for unit in SelectionManager.selected_units:
		if not is_instance_valid(unit):
			continue
		if context and not context.contains(unit):
			continue
		selected_here = true
		if unit.in_combat() and unit.is_my_turn():
			return unit

	# They picked somebody in THIS world and that person is not waiting on
	# a turn, so there is nothing to end. A selection left behind in
	# another world is not an opinion about this one, and falls through.
	if selected_here:
		return null

	for unit in PartyManager.members:
		if not is_instance_valid(unit) or not unit.in_combat() or not unit.is_my_turn():
			continue
		if context and not context.contains(unit):
			continue
		return unit
	return null


func _refresh() -> void:
	visible = _acting_unit() != null


func _on_combat_changed(_arg) -> void:
	_refresh()


func _on_selection_changed(_selected_units: Array[Unit]) -> void:
	_refresh()


func _on_world_focused(_world: Node) -> void:
	_refresh()


func _on_pressed() -> void:
	# That unit's own fight, not the focused encounter's — with a split
	# party those are not always the same one.
	var unit: Unit = _acting_unit()
	if unit:
		CombatManager.end_turn(unit)
