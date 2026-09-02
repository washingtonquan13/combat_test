extends AiTestCase
## When a load fails, the front end stays on screen and says why.
##
## This is the surface the original report was about: "the main menu is
## still up, with the world underneath, unless I load the save twice in a
## row". The cause of THAT was a deadlock further down (fixed by splitting
## the travel gate — see test_load_restores_combat_elsewhere), so the menu
## no longer hangs around after a load that works.
##
## What was left afterwards is the opposite risk, and it is the reason this
## suite exists rather than one asserting the menu closes harder: a load
## that FAILS must leave the player somewhere they can act. The planned fix
## for this phase was to close the title screen whenever a load attempt
## ended, success or failure — which would have left a failed load showing
## an empty SceneRoot with no interface on it at all. Strictly worse than
## the bug being fixed.
##
## So the panel deliberately stays open on failure, and now carries the
## reason. Asserted through is_visible_in_tree() rather than through
## UIStack membership: a suite in this project has already gone green on
## manager state while the panels it described were invisible.

var _panel: SaveLoadPanel = null
var _menu: UIScreen = null
var _layer: CanvasLayer = null


func run() -> void:
	_layer = CanvasLayer.new()
	_root.add_child(_layer)

	_menu = preload("res://ui/main_menu.tscn").instantiate()
	_layer.add_child(_menu)
	_panel = preload("res://ui/save_load_panel.tscn").instantiate()
	_layer.add_child(_panel)
	await get_tree().process_frame

	UIStack.push(_menu)
	_panel.open_for(SaveLoadPanel.Mode.LOAD)
	await get_tree().process_frame

	var status: Label = _panel.get_node("%StatusLabel")

	check("SETUP: the load screen is actually on screen",
		_panel.is_visible_in_tree(),
		"the panel is not rendered, so nothing below tests what it claims")
	check("SETUP: and it starts with nothing to report",
		not status.is_visible_in_tree())

	# A real failed load, not a hand-emitted signal. Nothing on disk at this
	# path, so it refuses at the first check and touches nothing.
	var ok: bool = SaveManager.load_file("user://a_save_that_is_not_there.cfg")
	await get_tree().process_frame

	check("a load of a missing file fails",
		not ok)

	check("the load screen stays up, so another save can be picked",
		_panel.is_visible_in_tree(),
		"the panel closed on a failure, leaving nowhere to retry from")

	check("and the title screen underneath is still there",
		_menu.is_visible_in_tree(),
		"closing this on a failed load would leave an empty screen with no UI")

	check("and the player is told why, on screen",
		status.is_visible_in_tree() and not status.text.strip_edges().is_empty(),
		"status label %s, text '%s' — a push_warning is not something a " % [
			"visible" if status.is_visible_in_tree() else "hidden", status.text] +
		"release build ever shows anyone")

	# Re-opening is a fresh attempt and must not still be showing the last
	# one's complaint.
	_panel.close()
	_panel.open_for(SaveLoadPanel.Mode.LOAD)
	await get_tree().process_frame
	check("and re-opening the screen clears the old message",
		not status.is_visible_in_tree(),
		"the previous failure is still on screen for an attempt that has " +
		"not happened yet")

	_cleanup()


func _cleanup() -> void:
	if is_instance_valid(_panel):
		if UIStack.is_open(_panel):
			UIStack.pop(_panel)
		_panel.queue_free()
	if is_instance_valid(_menu):
		if UIStack.is_open(_menu):
			UIStack.pop(_menu)
		_menu.queue_free()
	if is_instance_valid(_layer):
		_layer.queue_free()
