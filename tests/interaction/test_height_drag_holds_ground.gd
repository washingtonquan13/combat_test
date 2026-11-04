extends AiTestCase
## A Ctrl height drag holds the ground point: while it is held every
## reader of the cursor's ground point gets the held spot, so the mouse
## only moves the height; letting go of Ctrl frees it.


func run() -> void:
	var reader := IndicatorBase.new()
	add_child(reader)
	var spot := Vector3(3.0, 0.0, -7.0)

	Input.action_press("fly_altitude_modifier")
	IndicatorBase._hold_ground(spot)
	check("held while Ctrl is down", reader._get_mouse_ground_point() == spot)

	Input.action_release("fly_altitude_modifier")
	reader._get_mouse_ground_point()
	check("letting go frees it", IndicatorBase._held_ground == null)
	reader.free()
