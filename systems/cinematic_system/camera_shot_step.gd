class_name CameraShotStep
extends SceneStep
## Puts the camera somewhere, immediately.
##
## THE LAST STEP TYPE, and deliberately so. On a timeline a shot is value
## tracks on a FramingRig — keyed, scrubbable, and interpolated in polar
## space so the move vocabulary falls out of the interpolation. This is the
## same framing asked for in one call, with no timeline to hang it on:
## dialogue_staging.gd re-framing a speaker mid-conversation, where a
## mounted stage per line would be absurd. Anything with a second beat in
## it belongs on a timeline.

@export var framing: CameraFraming

## How long the camera takes to get there. ZERO IS A CUT, and zero is the
## default — deliberately.
##
## Coverage cuts. Sweeping smoothly from one face to another reads as a
## disorienting swoop rather than as shot and reverse, so a conversation
## must never transit by accident. Anything non-zero has to be asked for.
@export var transit_seconds: float = 0.0
## Passed to ease(). Negative curves ease in and out; 1.0 is linear.
@export var ease_curve: float = -2.0


func apply(cast: SceneCast) -> void:
	if framing == null:
		return
	var camera: CinematicCamera = CinematicDirector.camera()
	if camera == null:
		return
	camera.frame(framing, cast, transit_seconds, ease_curve)


func describe() -> String:
	if framing == null:
		return "camera shot (no framing) at %.2fs" % offset
	var how: String = "cut" if transit_seconds <= 0.0 else "%.2fs transit" % transit_seconds
	return "camera on '%s' (%s) at %.2fs" % [framing.subject_role, how, offset]
