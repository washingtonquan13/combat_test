class_name UIScreen
extends Control
## Base class for any UI panel managed by UIStack (EscMenu, PartyOverview,
## StashPanel, DialogueOverlay, ConversationLog, NegotiationPanel) — a
## screen's own visible state is owned by UIStack, not assigned directly
## by this script or by any sibling reaching in. See UIStack's own header
## for the bug class this replaces: a hand-rolled `sibling.visible = true`
## on close used to wrongly reveal something ELSE had hidden, since
## nothing tracked who else currently wanted it hidden. Call open()/
## close() rather than setting visible yourself.
##
## The three exported fields are data, not behavior: UIStack reads them
## to decide (a) whether MainRoot's gameplay HUD should stay hidden while
## this screen is open, (b) whether a NEW screen is allowed to open while
## this one is (a modal loot/dialogue screen blocking something else from
## opening on top of it), and (c) whether Escape closes this screen when
## it's the topmost thing currently open. None of these affect the 3D
## world's own input/camera control (CameraDirector.has_control()) — that
## integration is separate, later work, deliberately not folded in here.

## Whether MainRoot's persistent gameplay HUD (hotbar, party panel,
## end-turn button, ...) should be hidden while this screen is open.
@export var hides_hud: bool = false
## Whether this screen being open refuses a NEW screen from opening on
## top of it (see UIStack.can_open()) — the modal/overlay split. A
## conversation or a loot screen blocks; a log/journal-style overlay
## usually shouldn't.
@export var blocks_input_below: bool = false
## Whether Escape closes this screen when it's the topmost closes_on_cancel
## screen open (see UIStack's own _unhandled_input). False for screens
## that shouldn't be casually dismissed mid-flow (dialogue, negotiation).
@export var closes_on_cancel: bool = true


func open() -> void:
	UIStack.push(self)


func close() -> void:
	UIStack.pop(self)
