extends Node
## Autoload singleton. Register as "GameMode" under
## Project > Project Settings > AutoLoad.
##
## Describes WHO OWNS INPUT AND THE CAMERA right now — not whether a
## fight is running. "Is THIS unit fighting" is still Unit.in_combat(),
## entirely separate and not absorbed here: negotiation started mid-combat
## means mode == NEGOTIATION while those units stay in combat underneath.
##
## DERIVED, NOT STORED. Nothing sets the mode; this asks. current_mode()
## recomputes from the world that is focused, the screens that are open
## and the fights that are running, every time it is called.
##
## It used to be an imperative stack with two independent writers and no
## contract between them. WorldManager replaced the whole stack on every
## world focus (set_base_mode did `_stack = [mode]`, silently discarding
## any overlay), while CombatManager pushed and popped against its OWN
## mirrored bookkeeping — a _combat_mode_depth counter and a _mode_claims
## array. Three copies of one fact, allowed to disagree.
##
## They did disagree, in a fixed order, every time focus moved off a
## fight: set_base_mode wiped the COMBAT entry, then CombatManager tried
## to pop an entry that was already gone, and the suite printed
## "GameMode.pop_mode refused: nothing to pop." Twice per run, green.
##
## That desync also deadlocked save loading outright — a restored fight
## claimed COMBAT, and the claim could only be released by moving focus,
## which the claim itself refused. See WorldManager.can_rebuild().
##
## The rule this now follows is the one the rest of the project already
## reached: a fact about the game lives in exactly one place, and anything
## else that wants it asks. Unit.in_combat() reads its own encounter,
## WorldManager.current_area() reads whatever is focused, and the mode
## reads all of them. There is nothing left to keep in sync.
##
## Dependency direction is one-way on purpose: GameMode asks
## CinematicDirector, CombatManager, the three modal managers, WorldManager
## and UIStack, and none of them asks GameMode back. It is registered after
## all of them in the autoload list, which is what makes that safe.
##
## OVERWORLD is deliberately its OWN base mode, not folded into
## EXPLORATION — the overworld has no tactical camera and nothing
## selectable, so CameraDirector.has_control() (EXPLORATION/COMBAT only)
## correctly excludes it without needing a special case.

enum Mode {
	MAIN_MENU, CHARACTER_CREATION, EXPLORATION, OVERWORLD,
	COMBAT, DIALOGUE, NEGOTIATION, LOOTING, CUTSCENE,
}

## Emitted when a recompute finds a different answer than last time. Kept
## for listeners that want to REACT to a change; anything making a
## DECISION should call current_mode() directly, which is always current
## rather than waiting for the next frame.
##
## CUTSCENE is produced by CinematicDirector.is_active(), and is asked
## FIRST — see current_mode() for why that position is load-bearing rather
## than arbitrary.
signal mode_changed(mode: Mode)

var _last_emitted: Mode = Mode.MAIN_MENU


## What owns input and the camera right now.
##
## Overlays are asked before the base, and in a fixed order.
##
## CUTSCENE IS ASKED FIRST, and that position matters. A cutscene can be
## staged FROM a dialogue — the dialogue is still running underneath, so
## DialogueManager.is_active() is still true — and if DIALOGUE were asked
## first a locked cinematic would report DIALOGUE and keep running
## dialogue's input rules. Nothing outranks the director while it holds
## the screen, which is the point of it holding the screen.
##
## Among the rest the order barely matters: the three modal managers
## already refuse to start over one another (see
## NegotiationManager.can_negotiate and DialogueManager.start_dialogue's
## matching guards), so at most one of them is ever active. COMBAT is
## asked LAST of the overlays because it is the one that genuinely
## coexists with them — negotiating mid-fight means NEGOTIATION, with the
## fight still running underneath.
func current_mode() -> Mode:
	if CinematicDirector.is_active():
		return Mode.CUTSCENE
	if NegotiationManager.is_active():
		return Mode.NEGOTIATION
	if DialogueManager.is_active():
		return Mode.DIALOGUE
	if StashManager.is_active():
		return Mode.LOOTING
	if CombatManager.a_watched_fight_is_running():
		return Mode.COMBAT
	return base_mode()


## The mode with nothing overlaid on it — a property of WHERE THE PLAYER
## IS, which is why it reads the focused world first and asks the world
## itself rather than deciding on its behalf (see GameArea.get_base_mode
## and overworld.gd's own override).
##
## With no world loaded the answer comes from the front end, which is a
## pair of UIScreens and not worlds at all (see main_menu.gd) — so this is
## the one place the mode looks at the UI layer. MAIN_MENU is the floor:
## it is what the game is before anything has been loaded or opened, which
## is exactly the state at boot.
func base_mode() -> Mode:
	var world: Node = WorldManager.current_world()
	if is_instance_valid(world) and world.has_method("get_base_mode"):
		return world.get_base_mode()
	if _front_end_screen_open(&"character_creation"):
		return Mode.CHARACTER_CREATION
	return Mode.MAIN_MENU


## Whether nothing is currently overlaid on the base mode — i.e. a world
## transition is safe (see WorldManager.can_travel()). True during
## MAIN_MENU/CHARACTER_CREATION/EXPLORATION/OVERWORLD with nothing on top;
## false the instant a fight the player is watching starts, or a
## dialogue/negotiation/loot screen opens.
##
## Says exactly what it means now: the mode IS the base mode, so nothing
## is layered over it. The old form counted stack entries, which is the
## same question only for as long as the stack is trustworthy.
##
## Deliberately distinct from CameraDirector.has_control() — that answers
## "does the tactical 3D camera get input right now" (EXPLORATION and
## COMBAT specifically), a different question with a different true set.
func can_transition() -> bool:
	return current_mode() == base_mode()


func _front_end_screen_open(group: StringName) -> bool:
	var screen: Node = get_tree().get_first_node_in_group(group)
	return screen is UIScreen and UIStack.is_open(screen)


## The only reason this node processes. Nothing needs to TELL the mode it
## changed — the answer is computed on demand — but a signal still has to
## be emitted from somewhere, and polling is what keeps that honest: there
## is no call site anyone can forget to add when a new thing starts
## affecting the mode.
##
## Cheap: four is_active() reads and a walk of the (never many) running
## encounters, once a frame.
func _process(_delta: float) -> void:
	var now: Mode = current_mode()
	if now != _last_emitted:
		_last_emitted = now
		mode_changed.emit(now)
