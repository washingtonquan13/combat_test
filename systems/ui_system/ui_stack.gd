extends Node
## Autoload singleton. Register as "UIStack" under
## Project > Project Settings > AutoLoad.
##
## Owns which UIScreens (EscMenu, PartyOverview, StashPanel,
## DialogueOverlay, ConversationLog, NegotiationPanel) are currently open,
## and derives from that — not from any one screen's own opinion — three
## things: whether MainRoot's gameplay HUD is hidden, whether a new screen
## is allowed to open, and which single screen Escape closes.
##
## Replaces a real bug class, not just a style preference. Several panels
## used to reach directly into a sibling's `.visible` field — dialogue
## hiding/restoring tactical_ui, negotiation doing the same, stash hiding
## party_overview — always restoring to `true`/`false` unconditionally,
## with no idea whether something ELSE also wanted that state. HUD
## visibility here is instead recomputed from every currently-open
## screen's own hides_hud flag on every push/pop, so it can never be
## wrong about "should something else have kept this hidden."
##
## Multiple screens CAN be open at once (EscMenu over PartyOverview,
## ConversationLog over DialogueOverlay) — this is a registry of what's
## open, not a "only the top is visible" stack in the strict sense. What
## IS stack-ordered is Escape: it closes the most-recently-opened
## closes_on_cancel screen, one press at a time, then falls back to
## opening the esc menu (found via the "esc_menu" group, same
## find-by-role idiom party_overview.gd/conversation_log.gd already use)
## once nothing is left to close.

var _stack: Array[UIScreen] = []
var _hud: Control = null
var _party_rail: Control = null


## Called once by MainRoot's own script with the TACTICAL HUD subtree
## (MainRoot/CanvasLayer/TacticalUI) — deliberately NOT the CanvasLayer
## itself. The CanvasLayer is the root of ALL UI, every UIScreen included,
## so hiding it would hide the very screen that asked for the HUD to be
## hidden. That was a real shipped bug: DialogueOverlay/NegotiationPanel
## set hides_hud=true, UIStack hid the whole CanvasLayer, and the dialogue
## and negotiation panels never appeared at all. "The HUD" means the
## gameplay chrome (initiative row, hotbar, end-turn button, system log,
## menu button) — a SIBLING of every screen, never their ancestor. The
## party rail is deliberately NOT part of this node anymore — see
## register_party_rail().
func register_hud(hud: Control) -> void:
	_hud = hud
	_update_hud_visibility()


## Called once by MainRoot's own script with PartyRail — a bare full-rect
## wrapper Control, SIBLING of TacticalUI (see MainRoot.tscn), that holds
## PartyPanel as its one child. Registered separately from register_hud()
## because the party rail's visibility rule is finer than the rest of the
## HUD's: most hides_hud screens (main menu, character creation) should
## take it down too, but a screen can opt out via UIScreen.
## keeps_party_visible — DialogueOverlay does, so a conversation still
## shows clickable party portraits while the initiative row, hotbar,
## end-turn button and system log are gone. Nesting PartyPanel under
## TacticalUI could never express that: a Control whose ANCESTOR is
## invisible is invisible in the tree no matter what its own `visible`
## flag says.
##
## It's PartyRail, a plain wrapper, that gets registered here — NOT
## PartyPanel directly — because PartyPanel already drives its OWN
## `visible` independently (hidden whenever the party has no rows; see
## party_panel.gd's _update_visibility()). Writing to PartyPanel.visible
## from here too would make two owners fight over the same flag: this
## rule would force it back on after a conversation even if the party
## happened to be empty at that exact moment, or the emptiness check
## could stomp a value this rule had just set. A wrapper Control this
## file toggles, with PartyPanel toggling its OWN visible independently
## underneath it, means is_visible_in_tree() is correctly the AND of
## both reasons — exactly how TacticalUI already relates to everything
## inside IT, just for one specific child instead of all of them.
func register_party_rail(rail: Control) -> void:
	_party_rail = rail
	_update_hud_visibility()


func push(screen: UIScreen) -> void:
	if screen in _stack:
		return
	_stack.append(screen)
	screen.visible = true
	_update_hud_visibility()


func pop(screen: UIScreen) -> void:
	if screen not in _stack:
		return
	_stack.erase(screen)
	screen.visible = false
	_update_hud_visibility()


## Closes every currently open screen — called by WorldManager.load_world()
## before freeing a world, so a screen showing data about to go stale
## (PartyOverview's currently-open unit, e.g.) doesn't linger open across
## the transition.
func close_all() -> void:
	for screen in _stack.duplicate():
		pop(screen)


## Closes every screen opened AFTER screen (screen itself stays open).
## No-op if screen isn't currently open.
func pop_to(screen: UIScreen) -> void:
	var index: int = _stack.find(screen)
	if index == -1:
		return
	for i in range(_stack.size() - 1, index, -1):
		pop(_stack[i])


func is_open(screen: UIScreen) -> bool:
	return screen in _stack


func is_top(screen: UIScreen) -> bool:
	return not _stack.is_empty() and _stack.back() == screen


## Whether anything currently open should refuse a NEW screen from
## opening — the generalized replacement for the ad hoc
## "DialogueManager.is_active() or StashManager.is_active()" guard
## party_overview.gd used to hand-roll. UI-to-UI blocking only — this
## does NOT gate CameraDirector.has_control()/3D-world input; that
## integration is separate, later work.
func can_open() -> bool:
	for screen in _stack:
		if screen.blocks_input_below:
			return false
	return true


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	if _pop_topmost_cancelable():
		get_viewport().set_input_as_handled()
		return
	var esc_menu: UIScreen = get_tree().get_first_node_in_group("esc_menu")
	if esc_menu:
		push(esc_menu)
		get_viewport().set_input_as_handled()


## Pops the most-recently-opened closes_on_cancel screen. Returns whether
## anything was actually closed.
func _pop_topmost_cancelable() -> bool:
	for i in range(_stack.size() - 1, -1, -1):
		if _stack[i].closes_on_cancel:
			pop(_stack[i])
			return true
	return false


func _update_hud_visibility() -> void:
	if _hud:
		_hud.visible = not _any_screen_hides_hud()
	if _party_rail:
		_party_rail.visible = not _any_screen_hides_party_rail()


func _any_screen_hides_hud() -> bool:
	for screen in _stack:
		if screen.hides_hud:
			return true
	return false


## True only when some open screen wants the party rail down TOO — a
## hides_hud screen that has NOT opted it back in via keeps_party_visible.
## Deliberately independent of _any_screen_hides_hud(): a stack holding
## only DialogueOverlay (hides_hud, keeps_party_visible) hides the rest of
## the HUD while this stays false, which is the entire point of the split.
func _any_screen_hides_party_rail() -> bool:
	for screen in _stack:
		if screen.hides_hud and not screen.keeps_party_visible:
			return true
	return false
