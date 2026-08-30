extends Node
## Autoload singleton. Register as "SelectionManager" under
## Project > Project Settings > AutoLoad.
##
## Tracks which Unit(s) are currently selected and keeps each Unit's own
## is_selected/highlight state in sync with this list. Ground clicks
## (see ground_click_target.gd) report here too, so clicking empty space
## clears the current selection.
##
## Only player-controlled units (Unit.is_player_controlled) can ever end
## up in selected_units — enforced here, not by callers, so no path (click
## routing, drag-select, a debug harness auto-selecting whoever's turn it
## is, anything written later) can put an enemy into a "selected" state.
## Interacting with an enemy is a direct action on click (e.g. attack),
## never a selection.

signal selection_changed(selected_units: Array[Unit])

var selected_units: Array[Unit] = []


func _ready() -> void:
	# The "debug harness auto-selecting whoever's turn it is" case named
	# above, now real — select() already no-ops on a hostile unit via its
	# own is_player_controlled() guard, so this needs no combat-side
	# awareness of who's allowed to be selected; it just always tries.
	# Non-additive: whichever units were selected during free-roam (or
	# left over from a previous turn) stop mattering the moment a new
	# turn starts — turn_started is CombatManager's one authoritative
	# "a unit's turn is now live" signal, fired from both normal turn
	# advance and the delay_turn path (see combat_manager.gd).
	CombatManager.turn_started.connect(select)


## additive = true (e.g. shift-click) adds to the current selection instead
## of replacing it. Clicking an already-selected unit with additive = true
## deselects just that unit (standard RTS/CRPG toggle behavior).
func select(unit: Unit, additive: bool = false) -> void:
	if not unit.is_player_controlled():
		return

	if additive and unit in selected_units:
		deselect(unit)
		return

	if not additive:
		_clear_all_except(unit)

	if unit in selected_units:
		return

	selected_units.append(unit)
	unit.set_selected(true)
	selection_changed.emit(selected_units)


## Adds a unit to the current selection without toggling. Unlike select(),
## this never deselects an already-selected unit — used for continuous
## updates (e.g. drag-select sweeping over a unit that's already selected)
## where a toggle would cause unwanted flicker.
func add(unit: Unit) -> void:
	if not unit.is_player_controlled():
		return
	if unit in selected_units:
		return
	selected_units.append(unit)
	unit.set_selected(true)
	selection_changed.emit(selected_units)


func deselect(unit: Unit) -> void:
	if unit not in selected_units:
		return
	selected_units.erase(unit)
	unit.set_selected(false)
	selection_changed.emit(selected_units)


func deselect_all() -> void:
	_clear_all_except(null)
	selection_changed.emit(selected_units)


func _clear_all_except(keep: Unit) -> void:
	# Rebuilt rather than erased-from. Nothing removes a unit from this
	# list when it leaves the tree, so a unit that dies or despawns while
	# selected leaves a dangling entry — and a dangling entry is not
	# merely awkward here: set_selected() on one takes the process down
	# with a segfault, and erase() on one is itself an error inside a
	# TypedArray. Filtering sidesteps both.
	var kept: Array[Unit] = []
	for u in selected_units:
		if not is_instance_valid(u):
			continue
		if u == keep:
			kept.append(u)
		else:
			u.set_selected(false)
	selected_units = kept
