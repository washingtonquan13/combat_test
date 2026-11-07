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
	#
	# Via a handler rather than connecting select directly, because
	# turn_started is relayed from EVERY encounter — including fights in
	# worlds the player is not looking at, which would otherwise yank the
	# selection to somebody on the other side of the map.
	CombatManager.turn_started.connect(_on_turn_started)
	CombatManager.combat_started.connect(_on_combat_started)
	CombatManager.unit_joined_combat.connect(_on_unit_joined_combat)
	CombatManager.unit_left_combat.connect(_on_combat_may_be_over)
	CombatManager.combat_ended.connect(_on_combat_may_be_over)


## Autoloads outlive nearly everything, but not each other's teardown
## order at quit or in a test harness that frees the tree: a connection
## left on CombatManager after this node is gone calls into a freed
## object. Mirrors the five connects in _ready exactly.
func _exit_tree() -> void:
	if CombatManager.turn_started.is_connected(_on_turn_started):
		CombatManager.turn_started.disconnect(_on_turn_started)
	if CombatManager.combat_started.is_connected(_on_combat_started):
		CombatManager.combat_started.disconnect(_on_combat_started)
	if CombatManager.unit_joined_combat.is_connected(_on_unit_joined_combat):
		CombatManager.unit_joined_combat.disconnect(_on_unit_joined_combat)
	if CombatManager.unit_left_combat.is_connected(_on_combat_may_be_over):
		CombatManager.unit_left_combat.disconnect(_on_combat_may_be_over)
	if CombatManager.combat_ended.is_connected(_on_combat_may_be_over):
		CombatManager.combat_ended.disconnect(_on_combat_may_be_over)


## Only a turn in the world on screen takes the selection. A fight
## elsewhere runs without stealing what the player is commanding — it
## asks for attention instead (see CombatManager's Attention section).
func _on_turn_started(unit: Unit) -> void:
	var context: WorldContext = WorldManager.context()
	if context and not context.contains(unit):
		return
	# Last chance to remember what the player had before the fight takes
	# the selection over — combat_started/unit_joined_combat normally got
	# there first, this covers a resumed save or anything that skips them.
	_remember_pre_combat(unit)
	select(unit)


# --- Restoring the selection after combat ----------------------------
#
# During a fight the selection is forced onto whoever's turn it is, so
# without this the player comes out of every battle commanding whichever
# party member happened to act last instead of the group they had.
#
# Scoped to the WORLD ON SCREEN, because several fights can run at once
# in several worlds. The snapshot is only taken when a party unit in the
# watched world enters a fight (the same scope _on_turn_started uses to
# decide whether a turn may take the selection at all), and it is only
# given back once no player-controlled unit in that world is still
# fighting. A far fight ending never restores anything: it never took
# the selection in the first place.

## What was selected when the party's fight began. Meaningless unless
## _has_pre_combat is set (an empty selection is a real snapshot).
var _pre_combat: Array[Unit] = []
var _pre_combat_context: WorldContext = null
var _has_pre_combat: bool = false
## Coalesces the burst of unit_left_combat + combat_ended a finishing
## fight emits into one check, run after finish() has released everyone.
var _restore_queued: bool = false


func _on_combat_started(turn_order: Array[Unit]) -> void:
	for unit in turn_order:
		_remember_pre_combat(unit)


func _on_unit_joined_combat(unit: Unit) -> void:
	_remember_pre_combat(unit)


## Snapshots the selection the first time a player unit in the watched
## world is drawn into a fight. Later entries (a second party member
## joining, the next turn) keep the original snapshot — by then the
## selection may already be the fight's, not the player's.
##
## A snapshot taken in a world the player has since left is stale and is
## replaced rather than blocking every future one.
func _remember_pre_combat(unit: Unit) -> void:
	if not is_instance_valid(unit) or not unit.is_player_controlled():
		return
	var context: WorldContext = WorldManager.context()
	if context and not context.contains(unit):
		return
	if _has_pre_combat and _pre_combat_context == context:
		return
	_pre_combat = []
	for u in selected_units:
		if is_instance_valid(u):
			_pre_combat.append(u)
	_pre_combat_context = context
	_has_pre_combat = true


func _on_combat_may_be_over(_arg = null) -> void:
	if not _has_pre_combat or _restore_queued:
		return
	_restore_queued = true
	_try_restore.call_deferred()


func _try_restore() -> void:
	_restore_queued = false
	if not _has_pre_combat:
		return
	var context: WorldContext = _pre_combat_context
	if _player_fighting_in(context):
		return

	var remembered: Array[Unit] = _pre_combat
	_pre_combat = []
	_pre_combat_context = null
	_has_pre_combat = false

	# The player has moved on to another world since: whatever they are
	# commanding there is theirs, and the old selection means nothing.
	if context != WorldManager.context():
		return

	var restored: Array[Unit] = []
	for u in remembered:
		if _can_restore(u, context):
			restored.append(u)
	if restored.is_empty():
		var leader: Unit = PartyManager.leader
		if _can_restore(leader, context):
			restored.append(leader)
	if restored.is_empty():
		return

	_clear_all_except(null)
	for u in restored:
		selected_units.append(u)
		u.set_selected(true)
	selection_changed.emit(selected_units)


## Whether any player-controlled unit in this world is still in a fight.
## A null context (no world loaded: the headless harness) means every
## unit counts, matching _on_turn_started's own null-context behaviour.
func _player_fighting_in(context: WorldContext) -> bool:
	for unit in UnitQuery.all_units(get_tree()):
		if not unit.is_player_controlled() or not unit.in_combat():
			continue
		if context == null or context.contains(unit):
			return true
	return false


## The lasting half of Unit.is_commandable(): alive, ours, standing, out
## of combat, not held by a status. NOT can_be_commanded()'s is_acting()
## half — the unit that landed the last blow is very likely still in its
## attack animation as the fight ends, and dropping it from the restored
## group for that would be wrong a frame later.
##
## Untyped `unit` on purpose: a remembered member may have died and been
## freed during the fight, and a typed parameter errors at the call on a
## freed object before the is_instance_valid guard can run.
func _can_restore(unit, context: WorldContext) -> bool:
	if not is_instance_valid(unit) or not unit.is_inside_tree():
		return false
	if not unit.is_alive() or unit.is_downed() or not unit.is_player_controlled():
		return false
	if unit.in_combat() or unit.status_prevents_turn():
		return false
	return context == null or context.contains(unit)


# --- Tab cycling -----------------------------------------------------

## Tab / Shift+Tab step the selection through the party in roster order.
## Gated like every other world input: nothing while a screen is up
## (UIStack.can_open()) or while the camera is not the player's
## (CameraDirector.has_control()).
##
## exact_match on both, because a plain Tab action also matches Shift+Tab
## under Godot's default (inclusive) modifier matching.
##
## F (swap_weapon_set) is handled here too, under the same gates, since it
## acts on the selection — see swap_selected_weapon_sets.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("swap_weapon_set", false, true):
		if UIStack.can_open() and CameraDirector.has_control() and swap_selected_weapon_sets():
			get_viewport().set_input_as_handled()
		return
	var step: int = 0
	if event.is_action_pressed("cycle_selection_previous", false, true):
		step = -1
	elif event.is_action_pressed("cycle_selection_next", false, true):
		step = 1
	if step == 0:
		return
	if not UIStack.can_open() or not CameraDirector.has_control():
		return
	if cycle_selection(step):
		get_viewport().set_input_as_handled()


## F: every selected unit the player can command right now swaps weapon
## sets (Unit.swap_weapon_set — free). is_commandable is the gate: not
## mid-action, and in a fight only on its own turn. Returns whether
## anyone swapped.
func swap_selected_weapon_sets() -> bool:
	var swapped: bool = false
	for unit in selected_units:
		if is_instance_valid(unit) and unit.is_commandable():
			unit.swap_weapon_set()
			swapped = true
	return swapped


## Selects the next (step 1) or previous (step -1) party member after the
## current one, skipping anyone the player cannot command right now.
## Returns whether the selection moved.
##
## Commandability does the combat scoping for free: a combatant is only
## commandable on its own turn, so mid-fight the cycle contains the unit
## whose turn it is plus any members standing outside the fight — the
## same set a click is allowed to select (see ClickRouter.click_unit).
## On an enemy's turn, with nobody outside the fight, it does nothing.
##
## Members only, not summons: Tab walks the party the portrait rail shows.
func cycle_selection(step: int) -> bool:
	var context: WorldContext = WorldManager.context()
	var roster: Array[Unit] = PartyManager.members
	if roster.is_empty():
		return false

	var anchor: Unit = null
	for u in selected_units:
		if is_instance_valid(u) and u in roster:
			anchor = u
			break
	var start: int = roster.find(anchor)
	if start == -1:
		# Nobody in the party selected: Tab lands on the first member,
		# Shift+Tab on the last.
		start = -1 if step > 0 else 0

	for i in range(1, roster.size() + 1):
		var candidate: Unit = roster[posmod(start + step * i, roster.size())]
		if candidate == anchor:
			break
		if not candidate.is_commandable():
			continue
		if context and not context.contains(candidate):
			continue
		select(candidate)
		return true
	return false


## additive = true (e.g. shift-click) adds to the current selection instead
## of replacing it. Clicking an already-selected unit with additive = true
## deselects just that unit (standard RTS/CRPG toggle behavior), unless it
## is the only one: a click never leaves the party with nobody selected.
func select(unit: Unit, additive: bool = false) -> void:
	if not unit.is_player_controlled():
		return

	if additive and unit in selected_units:
		if selected_units.size() > 1:
			deselect(unit)
		return

	if not additive:
		var before: int = selected_units.size()
		_clear_all_except(unit)
		# Already selected among others: dropping the others is still a
		# change, or whoever was first stays on the hotbar.
		if unit in selected_units:
			if selected_units.size() != before:
				selection_changed.emit(selected_units)
			return

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
