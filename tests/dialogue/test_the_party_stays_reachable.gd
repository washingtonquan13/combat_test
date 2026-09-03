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
	SelectionManager.deselect_all()
	portrait_a.pressed.emit()
	check("clicking a portrait during the conversation selects its unit",
		SelectionManager.selected_units.has(_a),
		"SelectionManager.selected_units is %s after the portrait's own " % [str(SelectionManager.selected_units)] +
		"pressed signal fired — the click either didn't reach _on_pressed " +
		"or _on_pressed itself got dialogue-gated")

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


## Stand-in shell for the slice of MainRoot.tscn this suite needs — see
## the header for exactly what is real (PartyPanel, DialogueOverlay) and
## what is a stand-in (TacticalUI and its two named children).
func _build_shell() -> void:
	_canvas = CanvasLayer.new()
	_root.add_child(_canvas)

	_tactical = Control.new()
	_tactical.name = "TacticalUI"
	_canvas.add_child(_tactical)

	_initiative_row = Control.new()
	_initiative_row.name = "InitiativeRow"
	_tactical.add_child(_initiative_row)

	_ability_hotbar = Control.new()
	_ability_hotbar.name = "AbilityHotbar"
	_tactical.add_child(_ability_hotbar)

	_party_rail = Control.new()
	_party_rail.name = "PartyRail"
	_canvas.add_child(_party_rail)

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
	_canvas.add_child(_overlay)

	UIStack.register_hud(_tactical)
	# PartyRail, not _panel — see main_root.gd's own register_party_rail
	# call and UIStack.register_party_rail()'s header for why registering
	# PartyPanel directly would be wrong.
	UIStack.register_party_rail(_party_rail)


func _restore() -> void:
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
