extends Node
## Autoload singleton. Register as "GameMode" under
## Project > Project Settings > AutoLoad.
##
## Describes WHO OWNS INPUT AND THE CAMERA right now — not whether a
## fight is running. CombatManager.in_combat stays the authoritative fight
## flag, entirely separate and not absorbed here: negotiation started
## mid-combat means mode == NEGOTIATION while in_combat stays true the
## whole time underneath.
##
## Two kinds of transition, kept deliberately distinct:
## - WORLD transitions (MAIN_MENU / CHARACTER_CREATION / EXPLORATION /
##   OVERWORLD) are mutually exclusive alternatives, one loaded world at a
##   time — see set_base_mode(), called by WorldManager.load_world() with
##   whatever the freshly loaded world's own duck-typed get_base_mode()
##   returns. This REPLACES the bottom of the stack rather than nesting,
##   the same "replace, don't stack" rule WorldManager itself already
##   follows for worlds — a new world isn't layered on top of the old one.
## - OVERLAY transitions (COMBAT / DIALOGUE / NEGOTIATION / LOOTING /
##   CUTSCENE) genuinely nest on top of whatever the current base is —
##   see push_mode()/pop_mode(). Restoring to what was underneath (not a
##   hardcoded fallback) is the actual point of this being a stack:
##   leaving a negotiation started mid-combat must return to COMBAT, not
##   silently drop to EXPLORATION — the identical restore-to-previous
##   lesson UIStack already applies to UI screens.
##
## OVERWORLD is deliberately its OWN base mode, not folded into
## EXPLORATION — the overworld has no tactical camera and nothing
## selectable, so CameraDirector.has_control() (EXPLORATION/COMBAT only)
## correctly excludes it without needing a special case, and nothing that
## already gates on has_control() (drag_select_box.gd, ground click
## routing, targeting indicators) needs to change to stay off there.

enum Mode {
	MAIN_MENU, CHARACTER_CREATION, EXPLORATION, OVERWORLD,
	COMBAT, DIALOGUE, NEGOTIATION, LOOTING, CUTSCENE,
}

signal mode_changed(mode: Mode)

var _stack: Array[Mode] = [Mode.MAIN_MENU]


func current_mode() -> Mode:
	return _stack.back()


## Called by WorldManager.load_world() — replaces the BASE of the stack
## (discarding anything overlaid on the old one) with the newly loaded
## world's own mode. Safe to assume nothing is overlaid at this point:
## WorldManager.can_load() already refuses a load whenever can_transition()
## is false, and UIStack.close_all() runs before every load too.
func set_base_mode(mode: Mode) -> void:
	_stack = [mode]
	mode_changed.emit(current_mode())


func push_mode(mode: Mode) -> void:
	_stack.append(mode)
	mode_changed.emit(current_mode())


func pop_mode() -> void:
	if _stack.size() <= 1:
		push_warning("GameMode.pop_mode refused: nothing to pop.")
		return
	_stack.pop_back()
	mode_changed.emit(current_mode())


## Whether nothing is currently overlaid on the base mode — i.e. a world
## transition is safe (see WorldManager.can_load()). True during
## MAIN_MENU/CHARACTER_CREATION/EXPLORATION with nothing stacked on top;
## false the instant COMBAT/DIALOGUE/NEGOTIATION/LOOTING/CUTSCENE is
## pushed. Deliberately distinct from CameraDirector.has_control() — that
## answers "does the tactical 3D camera get input right now" (true during
## EXPLORATION and COMBAT specifically), a different question with a
## different true set.
func can_transition() -> bool:
	return _stack.size() <= 1
