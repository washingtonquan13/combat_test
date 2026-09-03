extends AiTestCase
## UnitSelection is a child Node of its Unit, and dies with it.
##
## The behaviour half of this suite is unremarkable and deliberately so:
## selecting through SelectionManager still flips unit.is_selected and
## still fires Unit's own selected/deselected relays, and a unit that dies
## is deselected with its ring switched off. Nothing about the component
## moving out of a RefCounted field and into the scene tree is supposed to
## be visible from outside Unit, and these checks are what says so.
##
## The half that is the point is the two connection-list checks.
## UnitSelection connects to GameMode.mode_changed, an AUTOLOAD signal, so
## the autoload holds a Callable pointing at the component for as long as
## the connection stands. While the component was a RefCounted that
## Callable held a STRONG reference to it: freeing the Unit did not free
## the component, the connection stayed in GameMode's list, and the next
## mode change anywhere in the game — a conversation opening two areas
## later — called update_highlight() on a component whose Unit had been
## freed, erroring on highlight_mesh. Not a rare path: an ordinary world
## reload frees every unit in the outgoing world, so it leaked one per
## party member per reload, with nothing having died at all.
##
## What this suite observes is exactly that: GameMode.mode_changed's own
## connection list, before the spawn and after the unit goes away. Two
## separate questions, because two separate things now guarantee it:
##
##  - _leaving_the_tree_releases_the_connection asks it of a unit pulled
##    out of the tree and NOT freed. That is UnitSelection._exit_tree
##    doing the work, and it is the check the disconnect there exists for.
##    Sabotage-verified: delete those two lines and this is the check that
##    goes red.
##  - _a_freed_unit_leaves_no_connection_behind asks it of a unit actually
##    freed. Being a Node is what carries this one: Godot severs every
##    signal connection an Object has when it is deleted, which is
##    precisely the guarantee a RefCounted could never reach, because the
##    connection itself was what kept it from ever being deleted.
##
## Against the old RefCounted component the suite cannot even ask: there
## was no child to find, so it fails at its first check. That is the
## honest shape of "this could not have been tested before" — the leak was
## invisible to anything that only asked Unit's public surface, because
## Unit's public surface stayed perfectly correct while a freed unit's
## component sat in an autoload's connection list.
##
## ONE DELIBERATE BEHAVIOUR CHANGE, not a refactor, covered by
## _a_reparented_unit_gets_its_connection_back. The connection is now made
## in UnitSelection._enter_tree rather than once in _ready, so a unit that
## is REPARENTED gets it back. WorldManager carries party units between
## worlds by reparenting them, and the old code's only connect site ran
## once in a unit's life — so the first time a party member travelled
## anywhere, its ring stopped recomputing on a mode change for the rest of
## the session. Nothing reported that: a ring that fails to clear when a
## conversation opens is wrong, not an error, and no test looked.
##
## No world needed. GameMode is an autoload and SelectionManager reads no
## world state on this path.


func run() -> void:
	_the_component_is_a_child_node()
	_selection_still_drives_the_units_own_signals()
	_leaving_the_tree_releases_the_connection()
	_a_reparented_unit_gets_its_connection_back()
	await _a_freed_unit_leaves_no_connection_behind()
	_a_dead_unit_is_deselected_and_unhighlighted()


## Visible in the remote scene tree, under its own name, as its own type —
## which is the second thing the move buys and the one a person notices
## while the game is running.
func _the_component_is_a_child_node() -> void:
	var unit: Unit = spawn_brute(0.0)

	var component: Node = unit.get_node_or_null("Selection")
	check("a spawned unit has a child named Selection", component != null)
	if component == null:
		return
	check("that child is a UnitSelection", component is UnitSelection)
	check("its parent is the unit itself", component.get_parent() == unit)


## Unit's four selection signals are relays over the component's own — the
## public facade has to be untouched by where the component now lives.
func _selection_still_drives_the_units_own_signals() -> void:
	var unit: Unit = spawn_brute(3.0)

	# A Dictionary, not two ints. GDScript lambdas capture by VALUE, so a
	# captured int is a private copy and every one of these counts would
	# read 0 no matter what fired; a Dictionary is captured as the same
	# reference, so the handler and this function see one object.
	var fired: Dictionary = {"selected": 0, "deselected": 0}
	unit.selected.connect(func(_u: Unit) -> void: fired["selected"] += 1)
	unit.deselected.connect(func(_u: Unit) -> void: fired["deselected"] += 1)

	SelectionManager.select(unit)
	check("selecting through SelectionManager marks the unit selected", unit.is_selected)
	check("Unit.selected fired exactly once", fired["selected"] == 1,
		"got %d" % fired["selected"])
	if unit.highlight_mesh:
		check("the highlight ring is showing while selected", unit.highlight_mesh.visible)

	SelectionManager.deselect(unit)
	check("deselecting clears it", not unit.is_selected)
	check("Unit.deselected fired exactly once", fired["deselected"] == 1,
		"got %d" % fired["deselected"])
	if unit.highlight_mesh:
		check("the highlight ring is off again", not unit.highlight_mesh.visible)


## UnitSelection._exit_tree, asked directly: a unit pulled out of the tree
## and left ALIVE has already released its autoload connection. Nothing
## has been freed at this point, so no engine-level cleanup can be
## covering for the component — the disconnect either ran or it did not.
##
## This is the check the disconnect exists for, and the one a sabotage of
## it turns red. It is also the same moment the old code covered by hand,
## from Unit._exit_tree; the behaviour is unchanged, only who remembers.
func _leaving_the_tree_releases_the_connection() -> void:
	var baseline: int = GameMode.mode_changed.get_connections().size()

	var unit: Unit = spawn_brute(12.0)
	check("SETUP: spawning added a mode_changed connection",
		GameMode.mode_changed.get_connections().size() == baseline + 1)

	var parent: Node = unit.get_parent()
	if parent:
		parent.remove_child(unit)
	check("leaving the tree releases the connection immediately, with nothing freed",
		GameMode.mode_changed.get_connections().size() == baseline,
		"baseline %d, now %d" % [baseline, GameMode.mode_changed.get_connections().size()])
	check("the unit and its component are both still alive",
		is_instance_valid(unit) and is_instance_valid(unit.get_node_or_null("Selection")))

	# Released through the harness like any other spawn — _release copes
	# with a unit that already has no parent.
	remove_spawned(unit)


## Travel, in miniature. A unit taken out of the tree and put back — which
## is all WorldManager does to a party member crossing between worlds — is
## listening again on the other side, and a mode change still recomputes
## its ring.
##
## This is the deliberate behaviour change; see the file header. Under the
## old code the ring stopped recomputing on the first trip and stayed
## stopped, so the second half of this check (the emit) is the half that
## describes what a player would have seen: a selection ring that no
## longer reacts to a conversation opening.
func _a_reparented_unit_gets_its_connection_back() -> void:
	var baseline: int = GameMode.mode_changed.get_connections().size()

	var unit: Unit = spawn_brute(15.0)
	var parent: Node = unit.get_parent()
	if parent == null or unit.highlight_mesh == null:
		check("SETUP: a parented unit with a highlight ring", false)
		return

	parent.remove_child(unit)
	parent.add_child(unit)
	check("a reparented unit is listening again",
		GameMode.mode_changed.get_connections().size() == baseline + 1,
		"baseline %d, now %d" % [baseline, GameMode.mode_changed.get_connections().size()])

	# Selected, so the ring SHOULD be on; then forced off behind the
	# component's back, so the only thing that can put it back is the
	# signal actually arriving and update_highlight recomputing from
	# is_selected. Asserting the connection count alone would not catch a
	# connection wired to the wrong place.
	SelectionManager.select(unit)
	unit.highlight_mesh.visible = false
	GameMode.mode_changed.emit(GameMode.current_mode())
	check("a mode change still recomputes a reparented unit's highlight",
		unit.highlight_mesh.visible)

	SelectionManager.deselect(unit)
	remove_spawned(unit)


## The leak, asked of the autoload directly. See this file's header.
func _a_freed_unit_leaves_no_connection_behind() -> void:
	var baseline: int = GameMode.mode_changed.get_connections().size()

	var unit: Unit = spawn_brute(6.0)
	var component: Node = unit.get_node_or_null("Selection")
	if component == null:
		check("SETUP: the unit has a Selection child to free", false)
		return

	check("spawning adds exactly one mode_changed connection",
		GameMode.mode_changed.get_connections().size() == baseline + 1,
		"baseline %d, now %d" % [baseline, GameMode.mode_changed.get_connections().size()])

	# Recorded as an id, not held as a reference. A reference is precisely
	# what kept the old component alive, so asking the question with one
	# would be asking a different question.
	var component_id: int = component.get_instance_id()

	# remove_spawned, not a bare queue_free: the harness's own release path
	# (out of the "units" group, out of the tree, then deferred free) is
	# what every other suite tears a unit down with, and it also keeps this
	# unit out of teardown's second pass.
	remove_spawned(unit)
	await get_tree().process_frame
	await get_tree().process_frame

	check("the freed unit's component is gone too", not is_instance_valid(component))

	var survivor: bool = false
	for connection in GameMode.mode_changed.get_connections():
		var callable: Callable = connection["callable"]
		var target: Object = callable.get_object()
		if target == null or not is_instance_valid(target):
			survivor = true
		elif target.get_instance_id() == component_id:
			survivor = true
	check("no mode_changed connection still points at the freed component", not survivor)
	check("mode_changed is back to its baseline connection count",
		GameMode.mode_changed.get_connections().size() == baseline,
		"baseline %d, now %d" % [baseline, GameMode.mode_changed.get_connections().size()])


## Death still strips selection and highlighting. Unit.handle_death no
## longer calls a teardown on the component by hand — the deselect below
## goes through SelectionManager exactly as it always did, and the ring
## going dark is update_highlight reacting to that, not to the death.
func _a_dead_unit_is_deselected_and_unhighlighted() -> void:
	var unit: Unit = spawn_brute(9.0)

	SelectionManager.select(unit)
	check("SETUP: selected before dying", unit.is_selected)

	# Through real damage, the same path UnitCombat takes to reach
	# handle_death. death_cleanup_delay is 2.0s on unit.tscn, so the node
	# is still here to be asked these questions.
	unit.take_damage(unit.current_hp)

	check("a dead unit is not selected", not unit.is_selected)
	check("a dead unit is out of SelectionManager's list",
		not SelectionManager.selected_units.has(unit))
	check("a dead unit is not box-hovered", not unit.get_node("Selection").box_hovered)
	if unit.highlight_mesh:
		check("a dead unit's highlight ring is off", not unit.highlight_mesh.visible)
