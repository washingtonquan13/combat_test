extends AiTestCase
## A Ctrl height drag holds the ground point: while it is held the
## router's cursor reports the held spot, so the mouse only moves the
## height; letting go of Ctrl frees it, and Ctrl over an intent with no
## height to drag holds nothing.

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
	router._held_ground = spot
	check("held while Ctrl is down", router.resolve_cursor(intent).ground == spot)

	intent.drags = false
	check("Ctrl over an intent with nothing to drag holds nothing",
		router.resolve_cursor(intent).ground != spot and router._held_ground == null)

	intent.drags = true
	router._held_ground = spot
	_ctrl(false)
	router.resolve_cursor(intent)
	check("letting go frees it", router._held_ground == null)

	router.free()


func _ctrl(down: bool) -> void:
	var event := InputEventAction.new()
	event.action = "fly_altitude_modifier"
	event.pressed = down
	Input.parse_input_event(event)
	Input.flush_buffered_events()
