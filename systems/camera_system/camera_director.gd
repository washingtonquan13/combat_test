extends Node
## Autoload singleton. Register as "CameraDirector" under
## Project > Project Settings > AutoLoad.
##
## The single arbitration point for "does the tactical camera currently
## get to respond to input" and "which camera is actually rendering right
## now" — crpg_camera.gd checks has_control() and nothing else, forever,
## regardless of how many systems eventually want to interrupt it. Before
## this, crpg_camera.gd checked InteractionMenu.is_open() directly; adding
## dialogue meant either a second hardcoded autoload reference right next
## to it, or centralizing here instead — the same scattered-condition-
## chain problem PlayerInteractionState already exists to prevent for
## click-routing, just showing up on the camera side.
##
## has_control() is a GameMode query — see that autoload for the full
## reasoning. CombatManager/DialogueManager/NegotiationManager/
## StashManager each push/pop their own GameMode.Mode when they start/end
## rather than exposing an is_active() for this file to aggregate by
## hand; adding a future blocker (a cutscene system) means giving it its
## own mode and possibly widening this function's allow-list, not adding
## a new hardcoded autoload reference here.
##
## InteractionMenu is the one deliberate exception, checked directly —
## it's a brief right-click context menu, not a genuine mode transition,
## so it was never folded into GameMode.

var _tactical_camera: Camera3D = null


## Called by crpg_camera.gd's own _ready() — this autoload has no other
## way to know which Camera3D is "the tactical one" to hand control back
## to once a cinematic shot ends. Also called (redundantly but harmlessly)
## by WorldManager.load_world() right after a newly loaded world enters
## the tree, so a world whose camera script doesn't self-register still
## gets registered and made current — see that file's own header.
func register_tactical_camera(cam: Camera3D) -> void:
	_tactical_camera = cam


## Called when a tactical camera is being retired (its world is about to
## be freed by WorldManager.load_world()) so a now-stale camera can't be
## handed control via deactivate_cinematic_camera(). Guarded on identity
## so an out-of-order call from a camera that ISN'T the currently-registered
## one can't clobber a legitimate registration.
func unregister_tactical_camera(cam: Camera3D) -> void:
	if _tactical_camera == cam:
		_tactical_camera = null


## True only during EXPLORATION and COMBAT — the two modes where a
## tactical 3D camera actually exists and should respond to input.
## Deliberately distinct from GameMode.can_transition() (which answers
## "is it safe to swap worlds right now," true for MAIN_MENU/
## CHARACTER_CREATION too) — a different question with a different true
## set.
func has_control() -> bool:
	if InteractionMenu.is_open():
		return false
	return GameMode.current_mode() in [GameMode.Mode.EXPLORATION, GameMode.Mode.COMBAT]


## Switches the viewport to cam — used by dialogue_camera_rig.gd (and any
## future cinematic system) instead of calling cam.make_current() directly,
## so there's exactly one place that knows how to hand control back
## afterward too (see deactivate_cinematic_camera).
func activate_cinematic_camera(cam: Camera3D) -> void:
	cam.make_current()


## Hands the viewport back to whichever camera registered itself as the
## tactical one. Safe to call even if nothing ever registered (a scene
## with no tactical camera at all), or if the registered camera has since
## been freed/unregistered without a replacement yet — just does nothing.
func deactivate_cinematic_camera() -> void:
	if is_instance_valid(_tactical_camera):
		_tactical_camera.make_current()
