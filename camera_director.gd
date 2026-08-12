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
## has_control() AGGREGATES known blockers rather than systems pushing
## ownership state into this autoload — each blocker's "am I active" state
## stays exactly where it already lives (InteractionMenu's own popup
## visibility, DialogueManager.is_active()), so there's nothing here that
## can drift out of sync with the thing it's supposed to reflect. Adding
## a future blocker (a cutscene system) is a one-line addition to this
## function, not a change to crpg_camera.gd at all.

var _tactical_camera: Camera3D = null


## Called once by crpg_camera.gd's own _ready() — this autoload has no
## other way to know which Camera3D is "the tactical one" to hand control
## back to once a cinematic shot ends.
func register_tactical_camera(cam: Camera3D) -> void:
	_tactical_camera = cam


func has_control() -> bool:
	return not InteractionMenu.is_open() and not DialogueManager.is_active()


## Switches the viewport to cam — used by dialogue_camera_rig.gd (and any
## future cinematic system) instead of calling cam.make_current() directly,
## so there's exactly one place that knows how to hand control back
## afterward too (see deactivate_cinematic_camera).
func activate_cinematic_camera(cam: Camera3D) -> void:
	cam.make_current()


## Hands the viewport back to whichever camera registered itself as the
## tactical one. Safe to call even if nothing ever registered (a scene
## with no tactical camera at all) — just does nothing.
func deactivate_cinematic_camera() -> void:
	if _tactical_camera:
		_tactical_camera.make_current()
