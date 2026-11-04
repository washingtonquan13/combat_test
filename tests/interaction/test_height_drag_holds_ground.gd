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

	# A drag the router switches off mid-press (a cast, an armed ability)
	# must not leave the next press holding nothing new.
	_ctrl(true)
	reader._handle_aim_height_input(spot)
	reader.set_live(false)
	_ctrl(false)
	_ctrl(true)
	reader.set_live(true)
	var next := Vector3(-4.0, 0.0, 2.0)
	reader._handle_aim_height_input(next)
	check("the next press holds the new spot", IndicatorBase._held_ground == next)
	_ctrl(false)
	AbilityManager.has_aim_height_override = false
	reader.free()


func _ctrl(down: bool) -> void:
	var event := InputEventAction.new()
	event.action = "fly_altitude_modifier"
	event.pressed = down
	Input.parse_input_event(event)
	Input.flush_buffered_events()
