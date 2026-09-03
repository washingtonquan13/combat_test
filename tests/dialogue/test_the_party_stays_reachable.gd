extends AiTestCase
## The party rail survives a conversation — the fix for the "party half
## of the dialogue UI rewrite": DialogueOverlay authors hides_hud=true in
## MainRoot.tscn, and UIStack used to own exactly one HUD node
## (CanvasLayer/TacticalUI) containing InitiativeRow, AbilityHotbar,
## SystemLog, PartyPanel and EndTurnButton together — so a conversation
## blanked the party portraits as pure collateral, with no way to select
## a party member while talking even though unit_portrait.gd's own press
## handler has never had any dialogue-awareness at all.
##
## The fix: PartyPanel now lives inside PartyRail, a bare Control wrapper
## that is a SIBLING of TacticalUI in MainRoot.tscn, and PartyRail (not
## PartyPanel itself) is what's registered with UIStack separately via
## register_party_rail(). A new UIScreen.keeps_party_visible flag (set
## true on DialogueOverlay's instance) tells UIStack to leave PartyRail
## up even while everything else authored under hides_hud goes down. See
## ui_stack.gd's _any_screen_hides_party_rail() and party_panel.gd's own
## header for the full mechanism, including why a wrapper and not
## PartyPanel's own `visible` flag.
##
## WHAT COULD NOT BE INSTANTIATED. MainRoot itself is not present in the
## headless test runner scene (see AiTestCase's own header), so this
## suite builds a stand-in shell rather than loading MainRoot.tscn:
##   - CanvasLayer -> TacticalUI (plain Control, standing in for the real
##     one) -> two plain Control children named "InitiativeRow" and
##     "AbilityHotbar" — NOT the real systems/combat_system components
##     (do-not-touch, and both need a live combat/turn state this suite
##     has no reason to stand up). What is under test is whether they sit
##     inside a Control that goes invisible, not their own contents.
##   - PartyRail (plain Control wrapper) -> PartyPanel: the REAL class
##     (party_panel.gd), built the same way
##     tests/world/test_party_panel_rows.gd already does — PartyPanel.new()
##     with a manually-built CoreContainer child added BEFORE the panel
##     enters the tree (its _core_container is @onready). The wrapper
##     matters, not just the panel: UIStack.register_party_rail() takes
##     PartyRail specifically, never PartyPanel directly — see that
##     method's own header for why (two independent owners of one
##     `visible` flag otherwise). Skipping the wrapper here would let a
##     real bug through unnoticed.
##   - DialogueOverlay: the REAL scene (systems/dialogue_system/
##     dialogue_overlay.tscn), instanced directly. hides_hud/
##     blocks_input_below/closes_on_cancel/keeps_party_visible are
##     authored as INSTANCE overrides on MainRoot.tscn's copy, not on the
##     base scene, so a standalone instance starts with every one of them
##     at its UIScreen default — this suite sets all four explicitly to
##     mirror MainRoot.tscn's actual authoring, keeps_party_visible=true
##     included (the one line this whole fix hinges on).
##
## Every visibility claim is asserted with is_visible_in_tree(), never a
## manager's own `visible` flag or the UIStack stack contents — this
## project once shipped a 32-of-32 green UI suite while the dialogue and
## negotiation panels rendered invisible, because every check asked a
## manager whether it THOUGHT something was open rather than looking at
## what actually rendered.

var _canvas: CanvasLayer
var _tactical: Control
var _initiative_row: Control
var _ability_hotbar: Control
var _party_rail: Control
var _panel: PartyPanel
var _overlay: UIScreen

var _a: Unit
var _b: Unit

var _saved_window_size: Vector2i = Vector2i.ZERO
var _saved_hud: Control = null
var _saved_party_rail: Control = null
var _saved_participants: Dictionary = {}


func run() -> void:
	_saved_hud = UIStack._hud
	_saved_party_rail = UIStack._party_rail
	_saved_participants = DialogueManager.participants.duplicate()

	_build_shell()
	await get_tree().process_frame

	_a = spawn_brute(0.0, 0.0)
	_b = spawn_brute(2.0, 0.0)
	PartyManager.add_member(_a)
	PartyManager.add_member(_b)
	await get_tree().process_frame

	var row_a: Control = _panel._core_rows.get(_a)
	var row_b: Control = _panel._core_rows.get(_b)
	if not is_instance_valid(row_a) or not is_instance_valid(row_b):
		check("SETUP: both party members got a row", false)
		_restore()
		return
	var portrait_a: Button = row_a.get_child(0)
	var portrait_b: Button = row_b.get_child(0)

	check("SETUP: PartyRail sits BEFORE DialogueOverlay under the shared CanvasLayer (mirrors MainRoot.tscn)",
		_party_rail.get_index() < _overlay.get_index(),
		"PartyRail is at child index %d, DialogueOverlay at %d — the rail is on TOP, so the " % [
			_party_rail.get_index(), _overlay.get_index()] +
		"negative-control click test below would prove nothing about real click-blocking")

	# --- baseline: nobody talking, the whole HUD is up -----------------
	check("SETUP: the party rail is visible before any conversation",
		_panel.is_visible_in_tree(),
		"the rail isn't even up outside a conversation — every check " +
		"below would be meaningless")
	check("SETUP: the stand-in initiative row is visible before any conversation",
		_initiative_row.is_visible_in_tree())

	# --- start a conversation -------------------------------------------
	var root_node := DialogueNode.new()
	root_node.id = "root"
	root_node.speaker = "npc"
	root_node.text_block = "Hold up a moment."
	DialogueManager.start_dialogue(root_node, {"player": _a, "npc": _b})
	await get_tree().process_frame

	check("SETUP: the conversation actually started",
		DialogueManager.is_active(),
		"start_dialogue() was refused (in combat? StashManager active?) " +
		"— every check below would be vacuous")

	# --- the party rail stays up, the rest of the HUD does not ---------
	check("the party panel is still visible during the conversation",
		_panel.is_visible_in_tree(),
		"PartyPanel went invisible along with the rest of the HUD — " +
		"keeps_party_visible didn't take effect")
	check("the stand-in initiative row is hidden during the conversation",
		not _initiative_row.is_visible_in_tree(),
		"InitiativeRow (inside TacticalUI) is still visible — the rest " +
		"of the HUD isn't actually being taken down")
	check("the stand-in ability hotbar is hidden during the conversation",
		not _ability_hotbar.is_visible_in_tree())
	check("and the overlay itself is on screen",
		_overlay.is_visible_in_tree(),
		"DialogueOverlay never actually opened — either it isn't listening " +
		"to dialogue_started, or open()/UIStack.push() is broken")

	# --- a portrait still selects its unit while talking ----------------
	# 2026-09-03 hardening (user requirement: "the background needs to
	# allow clicking portraits through it"). Calling portrait_a.pressed
	# .emit() by hand bypasses hit-testing entirely — a scrim or some
	# other Control sitting on top and swallowing every click would leave
	# this check green while a real player could never actually click the
	# portrait, which is exactly the bug class this whole file exists to
	# catch (see the header's own "32-of-32 green" note). Kept only as a
	# SETUP sanity check — does the portrait's own press handler select
	# the unit at all, wiring aside — the real proof is the hit-tested
	# click below.
	SelectionManager.deselect_all()
	portrait_a.pressed.emit()
	check("SETUP: the portrait's own press handler selects its unit (direct call, not hit-tested)",
		SelectionManager.selected_units.has(_a),
		"SelectionManager.selected_units is %s after the portrait's own " % [str(SelectionManager.selected_units)] +
		"pressed signal fired — the click either didn't reach _on_pressed " +
		"or _on_pressed itself got dialogue-gated")

	# REAL hit test: a synthesised click through the viewport's own input
	# pipeline (press then a matching release, both at the portrait's
	# actual global rect centre) — see
	# tests/interaction/test_intent_has_one_owner.gd's
	# _the_router_runs_before_the_indicators_it_drives for the same
	# push_input() pattern. This is what actually proves the background
	# (the overlay, its band, whatever the other agent lands) is not
	# sitting on top of the party rail eating the click before it reaches
	# the portrait — pressed.emit() above could never have caught that.
	#
	# Counted via a Dictionary rather than a plain bool: GDScript lambdas
	# capture outer locals BY VALUE, so a `var fired := false` closed over
	# by the connected lambda would never be visible to the check
	# afterward — only a container (Dictionary here), mutated in place
	# from inside the closure, actually is.
	SelectionManager.deselect_all()
	var press_count: Dictionary = {"count": 0}
	var on_pressed: Callable = func() -> void:
		press_count["count"] += 1
	portrait_a.pressed.connect(on_pressed)

	var portrait_center: Vector2 = portrait_a.get_global_rect().get_center()
	_click_at(portrait_center)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	check("a real, hit-tested click at the portrait's own rect centre reaches it through the viewport's input pipeline",
		press_count["count"] == 1,
		("portrait.pressed fired %d times from a synthesised click+release at its own global rect " +
			"centre (%s) — 0 means something above it is eating the click. Capturing controls " +
			"under that point, deepest last: %s") % [
			press_count["count"], str(portrait_center), _capturing_controls_at(portrait_center)])
	check("...and that real click selects its unit",
		SelectionManager.selected_units.has(_a),
		"SelectionManager.selected_units is %s after a real hit-tested click on the portrait" % str(SelectionManager.selected_units))
	portrait_a.pressed.disconnect(on_pressed)

	# Negative control, so the check above cannot pass vacuously (e.g. a
	# stray event.position of (0,0) that happens to land on SOMETHING
	# clickable regardless of where it was aimed): the same click+release
	# sequence aimed at the overlay's own BAND — comfortably away from the
	# party rail — must NOT reach the portrait at all.
	var band: Control = _overlay.find_child("Band", true, false)
	if band == null:
		check("SETUP: the overlay's Band exists for the negative-control click", false)
	else:
		SelectionManager.deselect_all()
		var band_press_count: Dictionary = {"count": 0}
		var on_pressed_band: Callable = func() -> void:
			band_press_count["count"] += 1
		portrait_a.pressed.connect(on_pressed_band)

		var band_center: Vector2 = band.get_global_rect().get_center()
		_click_at(band_center)
		await get_tree().process_frame
		await get_tree().process_frame
		await get_tree().process_frame

		check("a click aimed at the overlay's own band does NOT reach the portrait (negative control)",
			band_press_count["count"] == 0,
			("portrait.pressed fired %d times from a click aimed at the band's centre (%s), not the " +
				"portrait — the positive hit-test check above would be meaningless if this weren't 0") % [
				band_press_count["count"], str(band_center)])
		portrait_a.pressed.disconnect(on_pressed_band)

	# --- the speaking marker follows the speaker ------------------------
	check("the NPC's line lights the NPC's own marker",
		portrait_b.speaking_marker.is_visible_in_tree(),
		"speaker_token 'npc' resolves to _b via participants, but its " +
		"marker never lit")
	check("and NOT the other party member's",
		not portrait_a.speaking_marker.is_visible_in_tree(),
		"both markers are lit at once — _set_speaking_unit isn't clearing " +
		"the ones that aren't the current speaker")

	DialogueManager.line_shown.emit("My turn to answer.", "player")
	await get_tree().process_frame
	check("and the marker MOVES when the speaker changes",
		portrait_a.speaking_marker.is_visible_in_tree()
			and not portrait_b.speaking_marker.is_visible_in_tree(),
		"marker stayed on the old speaker (or lit both) after a new " +
		"line_shown for a different token")

	# --- ending the conversation restores the full HUD -------------------
	DialogueManager.end_dialogue()
	await get_tree().process_frame

	check("ending the conversation brings the initiative row back",
		_initiative_row.is_visible_in_tree(),
		"the rest of the HUD stayed hidden after dialogue_ended")
	check("and the ability hotbar",
		_ability_hotbar.is_visible_in_tree())
	check("and the party panel is still visible (never actually left)",
		_panel.is_visible_in_tree())
	check("and the overlay itself closes",
		not _overlay.is_visible_in_tree(),
		"DialogueOverlay is still open after dialogue_ended")
	check("and the speaking marker clears with nobody talking",
		not portrait_a.speaking_marker.is_visible_in_tree()
			and not portrait_b.speaking_marker.is_visible_in_tree(),
		"a marker is still lit after the conversation ended")

	# --- PartyRail toggles, PartyPanel keeps its OWN visible flag ------
	# The hazard: party_panel.gd's _update_visibility() already owns the
	# panel's own `visible` flag (it hides a panel with no rows). If UIStack
	# wrote to that same flag, one property would have two owners and
	# whichever ran last would win.
	#
	# The probe is a screen that DOES take the rail down: hides_hud with
	# keeps_party_visible false, which is every screen except a
	# conversation. With the rail hidden, the panel must be out of the tree
	# while its OWN flag is still true. Were UIStack writing to the panel
	# directly, that flag would read false instead.
	#
	# Emptying the party was the first version of this check and it was
	# wrong: PartyManager.everyone() also returns roster RECORDS, which
	# produce their own rows, so removing the two live Units leaves the
	# panel legitimately populated and visible.
	var blanker := UIScreen.new()
	blanker.name = "Blanker"
	blanker.hides_hud = true
	blanker.keeps_party_visible = false
	_canvas.add_child(blanker)
	UIStack.push(blanker)
	await get_tree().process_frame
	check("a screen that blanks the party takes the RAIL down",
		not _panel.is_visible_in_tree(),
		"the rail did not hide for a screen with keeps_party_visible false")
	check("and it never touches the panel's own visible flag",
		_panel.visible,
		"PartyPanel.visible is false — UIStack is writing to the panel " +
		"itself instead of the PartyRail wrapper, which puts two owners on " +
		"one property and fights _update_visibility()")
	UIStack.pop(blanker)
	await get_tree().process_frame
	check("and popping it brings the rail back",
		_panel.is_visible_in_tree(),
		"the rail stayed hidden after the blanking screen closed")
	blanker.queue_free()

	_the_real_scene_asks_for_it()

	_restore()


## A real left-click, press then release, both synthesised at `pos` and
## delivered through the actual viewport input pipeline (Control
## hit-testing, mouse_filter, z-order all included) — not a direct
## `.pressed.emit()` call. See the pressed-through-hit-test checks above
## for why that distinction is the entire point of this hardening pass.
## Every visible Control anywhere in the tree that would capture a click at
## `point` (mouse_filter STOP or PASS, rect contains the point), as a
## path list. Walks the WHOLE tree from the root, not this suite's shell,
## because a stale node another suite left behind is exactly the kind of
## thing that eats a click in a full run and not in a solo one.
func _capturing_controls_at(point: Vector2) -> String:
	var found: PackedStringArray = []
	var stack: Array[Node] = [get_tree().root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is Control and node.is_visible_in_tree() \
				and node.mouse_filter != Control.MOUSE_FILTER_IGNORE \
				and node.get_global_rect().has_point(point):
			found.append("%s[%s]" % [node.get_path(), "STOP" if node.mouse_filter == 0 else "PASS"])
	# A popup is a Window, not a Control, and an exclusive one steals every
	# input event without ever appearing in the list above. Likewise a
	# mouse press some earlier suite never released pins the viewport's
	# mouse focus to whatever it pressed on. Both are viewport state, not
	# tree geometry, so name them explicitly.
	var windows: PackedStringArray = []
	for child in get_tree().root.get_children():
		if child is Window and child != get_tree().root and child.visible:
			windows.append("%s(exclusive=%s)" % [child.get_path(), str(child.exclusive)])
	var focus: Control = get_viewport().gui_get_focus_owner()
	var summary: String = ", ".join(found) if not found.is_empty() else "(none)"
	summary += " | visible windows: %s" % (", ".join(windows) if not windows.is_empty() else "(none)")
	summary += " | key focus: %s" % (str(focus.get_path()) if focus else "(none)")
	summary += " | dragging: %s" % str(get_viewport().gui_is_dragging())
	summary += " | hovered: %s" % str(get_viewport().gui_get_hovered_control())
	return summary


func _click_at(pos: Vector2) -> void:
	# Motion first, so the viewport's hover state resolves at this point
	# the way it would under a real mouse before a real click. A bare
	# press with no prior motion is legal but is not what a player does,
	# and it leaves gui_get_hovered_control() null in the diagnostic.
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	get_viewport().push_input(motion)

	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	press.global_position = pos
	get_viewport().push_input(press)

	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = pos
	release.global_position = pos
	get_viewport().push_input(release)


## Stand-in shell for the slice of MainRoot.tscn this suite needs — see
## the header for exactly what is real (PartyPanel, DialogueOverlay) and
## what is a stand-in (TacticalUI and its two named children).
##
## Child ORDER under _canvas deliberately mirrors MainRoot.tscn:
## PartyRail is added BEFORE DialogueOverlay, so the overlay is the LATER
## sibling — later CanvasItem siblings sit on top and are hit-tested
## first, same as in the real scene. A suite that put the rail on top of
## the overlay here would prove nothing about the negative-control click
## test below: a click aimed at the band could only ever miss the
## portrait for the wrong reason (the rail simply wasn't underneath it).
func _build_shell() -> void:
	# The ROOT WINDOW is resized to the design size, not just a host
	# Control inside it. The headless runner's window is 64px tall, and a
	# synthesised mouse event outside the window rect is discarded before
	# any hit-test runs. In a solo run the portrait happened to sit at
	# y=26 and the click landed; after a full run's worth of roster
	# records the rail was taller, the portrait sat at y=250, and the very
	# same click silently vanished. Restored in _restore().
	_saved_window_size = get_tree().root.size
	get_tree().root.size = Vector2i(1600, 900)

	_canvas = CanvasLayer.new()
	_root.add_child(_canvas)

	# A screen at the game's real design size, and everything anchors to
	# it. The headless runner's own viewport is 64px tall; hung straight
	# off the CanvasLayer, the overlay's content-sized band (~260px, pinned
	# 29px up) spanned that whole viewport and its choice rows sat over
	# the portrait at (20, 26). The hit-test then reported the overlay
	# eating the click, which was true in that geometry and false in the
	# game's, where the rail is at mid-height and the band at the bottom.
	var screen := Control.new()
	screen.name = "Screen"
	screen.size = Vector2(1600, 900)
	_canvas.add_child(screen)

	_tactical = Control.new()
	_tactical.name = "TacticalUI"
	_tactical.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.add_child(_tactical)

	_initiative_row = Control.new()
	_initiative_row.name = "InitiativeRow"
	_tactical.add_child(_initiative_row)

	_ability_hotbar = Control.new()
	_ability_hotbar.name = "AbilityHotbar"
	_tactical.add_child(_ability_hotbar)

	_party_rail = Control.new()
	_party_rail.name = "PartyRail"
	_party_rail.set_anchors_preset(Control.PRESET_FULL_RECT)
	_tactical.get_parent().add_child(_party_rail)

	_panel = PartyPanel.new()
	_panel.name = "PartyPanel"
	_panel.slot_scene = load("res://ui/unit_portrait.tscn")
	var core := VBoxContainer.new()
	core.name = "CoreContainer"
	_panel.add_child(core)
	_party_rail.add_child(_panel)

	_overlay = load("res://systems/dialogue_system/dialogue_overlay.tscn").instantiate()
	# Mirrors MainRoot.tscn's own instance overrides on DialogueOverlay —
	# see the header on why these can't come from the base scene.
	_overlay.hides_hud = true
	_overlay.blocks_input_below = true
	_overlay.closes_on_cancel = false
	_overlay.keeps_party_visible = true
	# Added AFTER _party_rail — see this function's own header comment.
	_party_rail.get_parent().add_child(_overlay)

	UIStack.register_hud(_tactical)
	# PartyRail, not _panel — see main_root.gd's own register_party_rail
	# call and UIStack.register_party_rail()'s header for why registering
	# PartyPanel directly would be wrong.
	UIStack.register_party_rail(_party_rail)


func _restore() -> void:
	if _saved_window_size != Vector2i.ZERO:
		get_tree().root.size = _saved_window_size
	if DialogueManager.is_active():
		DialogueManager.end_dialogue()
	DialogueManager.participants = _saved_participants
	for unit in [_a, _b]:
		if is_instance_valid(unit) and PartyManager.is_member(unit):
			PartyManager.remove_member(unit)
	SelectionManager.deselect_all()
	UIStack._hud = _saved_hud
	UIStack._party_rail = _saved_party_rail
	UIStack._update_hud_visibility()


## The AUTHORED wiring, read as TEXT out of MainRoot.tscn.
##
## Everything above builds its own shell and sets the flags in code, which
## proves the mechanism works but says nothing about whether the real scene
## asks for it. Deleting keeps_party_visible from MainRoot.tscn left this
## whole suite green, and that is exactly the failure this project has
## already shipped twice: the Godot editor rewriting a .tscn from a stale
## cache and silently dropping a line somebody added externally. Once it
## landed as a commit.
##
## Read as text rather than through load() or PackedScene.get_state():
## loading MainRoot.tscn inside the runner BLOCKS, because the scene pulls
## in the whole game shell. Reading the file is the same trick
## test_a_scene_can_direct_a_performance.gd uses on a source file.
func _the_real_scene_asks_for_it() -> void:
	var file := FileAccess.open("res://MainRoot.tscn", FileAccess.READ)
	if file == null:
		check("SETUP: MainRoot.tscn is readable", false, "could not open the scene file")
		return
	var text: String = file.get_as_text()
	file.close()

	var at: int = text.find("[node name=\"DialogueOverlay\"")
	check("SETUP: MainRoot.tscn still has a DialogueOverlay node",
		at != -1,
		"no node named DialogueOverlay in the authored scene")
	if at == -1:
		return

	var next: int = text.find("[node ", at + 6)
	var block: String = text.substr(at, (next - at) if next != -1 else -1)

	check("the authored overlay keeps the party visible",
		block.contains("keeps_party_visible = true"),
		"MainRoot.tscn's DialogueOverlay does not set keeps_party_visible " +
		"= true, so the party rail vanishes during a conversation no matter " +
		"what this suite's own shell proves")
	check("and still hides the rest of the HUD",
		block.contains("hides_hud = true"),
		"MainRoot.tscn's DialogueOverlay does not set hides_hud = true, so " +
		"the initiative row and hotbar would stay up during a conversation")
