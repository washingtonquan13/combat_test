class_name DraggingIntent
extends PlayerIntent
## A MovableProp is being dragged (see PropDrag): the release drops it,
## right-click puts it back, the wheel turns it. Pushed by ClickRouter when a press on a
## movable prop turns into a drag, popped on drop or cancel.
##
## No indicators: the ghost is the preview, and a move or aim overlay
## under it would promise a click that isn't coming.

var drag: PropDrag


func _init(with_drag: PropDrag) -> void:
	drag = with_drag


func kind() -> StringName:
	return &"dragging_prop"


## Right-click while holding cancels; the prop never left its spot.
func handle_right_click(router, _cursor: Cursor) -> bool:
	router.cancel_prop_drag()
	return true


## The wheel turns the held prop instead of zooming the camera.
func handle_wheel(_router, steps: float) -> bool:
	if drag == null:
		return false
	drag.turn(steps)
	return true


func describe() -> String:
	return "dragging %s" % (drag.prop.name if drag and is_instance_valid(drag.prop) else "nothing")
