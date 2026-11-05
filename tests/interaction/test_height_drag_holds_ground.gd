extends AiTestCase
## A Ctrl height hold keeps its spot: while it is held the router's
## cursor reports the held spot, so the mouse only moves the height;
## letting go of Ctrl frees the spot but the height STAYS latched as a
## plane, and with the plane up the cursor is where the mouse ray crosses
## it (midair, on_plane). Ctrl over an intent with no height to drag
## holds nothing.

const ROUTER_SCRIPT: GDScript = preload("res://systems/indicator_system/ground_click_target.gd")


class DragIntent extends PlayerIntent:
	var drags: bool = true

	func kind() -> StringName:
		return &"drag_probe"

	func drags_height(_router) -> bool:
		return drags


func run() -> void:
	var router: Node3D = Node3D.new()
	router.set_script(ROUTER_SCRIPT)
	add_child(router)
	router.set_process(false)
	var intent := DragIntent.new()
	var spot := Vector3(3.0, 0.0, -7.0)

	_ctrl(true)
	router.resolve_cursor(intent)
	router._held_ground = spot
	check("held while Ctrl is down", router.resolve_cursor(intent).ground == spot)

	intent.drags = false
	check("Ctrl over an intent with nothing to drag holds nothing",
		router.resolve_cursor(intent).ground != spot and router._held_ground == null)

	intent.drags = true
	router.resolve_cursor(intent)
	router._held_ground = spot
	router.resolve_cursor(intent)
	_ctrl(false)
	router.resolve_cursor(intent)
	check("letting go frees the spot but keeps the height",
		router._held_ground == null and router._plane_height != null)

	# A camera high up looking down: the latched plane is nearer than the
	# floor under the mouse, so the cursor is the ray's crossing of the
	# plane, and floor_below the surface straight under that.
	var camera := Camera3D.new()
	add_child(camera)
	camera.global_position = Vector3(0.0, 30.0, 0.0)
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	camera.make_current()
	router._plane_height = 4.0
	var at: Cursor = router.resolve_cursor(intent)
	check("the cursor meets the latched plane midair",
		at.on_plane and at.ground is Vector3 and is_equal_approx(at.ground.y, 4.0)
			and at.plane_height == 4.0 and at.floor_below is Vector3
			and is_equal_approx(at.floor_below.x, at.ground.x) and at.floor_below.y < at.ground.y,
		"ground %s on_plane %s plane %s floor %s" % [at.ground, at.on_plane, at.plane_height, at.floor_below])

	camera.free()
	router.free()


func _ctrl(down: bool) -> void:
	var event := InputEventAction.new()
	event.action = "fly_altitude_modifier"
	event.pressed = down
	Input.parse_input_event(event)
	Input.flush_buffered_events()
