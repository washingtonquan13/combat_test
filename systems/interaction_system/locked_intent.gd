class_name LockedIntent
extends PlayerIntent
## Something else owns the screen — a conversation, a negotiation, a loot
## screen, a cutscene, an open context menu, the main menu. CameraDirector
## .has_control() answers exactly that question already (a click should
## not be able to reach the world in any state where the camera is frozen
## out of responding to input either), so this is derived from it rather
## than from a second list of the same conditions.
##
## Handles nothing and consumes nothing: the click is left unhandled, so
## the UI that actually owns the screen is unaffected, and no indicator
## is live because nothing is being aimed at a world you are not
## currently commanding.
##
## This is the one that used to be a bare `return` at the top of the
## router's _unhandled_input, with Unit._on_input_event separately
## checking only DialogueManager.is_active() — so a click on a unit
## during a NEGOTIATION, a loot screen or a cutscene still selected or
## attacked it. Deriving the lock in one place is what closes that.

func kind() -> StringName:
	return &"locked"


func describe() -> String:
	return "locked"
