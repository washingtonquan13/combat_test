extends AiTestCase
## Entering a place from the overworld: the avatar's icon shrinks down
## into the door before the trip starts, the SMT way, and a held key does
## not walk it off the door meanwhile. And in the tactical view its icon
## is drawn smaller on screen than in the follow view.
##
## The trip is a callback here, not a real load: what is asserted is the
## order (gone first, then the trip) and the icon's size, not WorldManager.


func run() -> void:
	var avatar: OverworldAvatar = preload("res://world/overworld_avatar.tscn").instantiate()
	avatar.icon_scale = 10.0
	_root.add_child(avatar)
	avatar.global_position = Vector3(0.0, 0.0, 0.0)
	avatar.active = true
	await get_tree().process_frame
	var pivot: Node3D = avatar.get_node("SpinPivot")
	var standing := pivot.scale.x

	var trips := [0]
	var shrunk_at_trip := [-1.0]
	avatar.enter(Vector3(3.0, 0.0, 4.0), func() -> void:
		trips[0] += 1
		shrunk_at_trip[0] = pivot.scale.x)
	# Entered twice, as a double press would: still one trip.
	avatar.enter(Vector3(3.0, 0.0, 4.0), func() -> void: trips[0] += 1)
	Input.action_press("camera_pan_forward")
	await get_tree().create_timer(avatar.enter_time * 0.8).timeout
	check("the icon is shrinking on the way in", pivot.scale.x < standing * 0.9,
		"%.3f of %.3f" % [pivot.scale.x, standing])
	check("and the trip has not started yet", trips[0] == 0)
	await get_tree().create_timer(avatar.enter_time * 0.5).timeout
	Input.action_release("camera_pan_forward")
	check("the trip starts once, after the icon has gone", trips[0] == 1 and shrunk_at_trip[0] < standing * 0.01,
		"trips %d, icon %.4f at the trip" % [trips[0], shrunk_at_trip[0]])
	var flat := Vector2(avatar.global_position.x, avatar.global_position.z)
	check("it went into the door, not where the held key walked it", flat.distance_to(Vector2(3.0, 4.0)) < 0.05,
		"stood at %s" % flat)

	avatar.stand()
	check("an avatar still here after its trip stands up again", is_equal_approx(pivot.scale.x, standing))
	avatar.queue_free()
	await get_tree().process_frame

	# The tactical view: the overworld's icon scale at full swing.
	var world: Node = preload("res://world/overworld.tscn").instantiate()
	_root.add_child(world)
	await get_tree().process_frame
	var camera: OverworldCamera = world.get_node("OverworldCamera")
	var follow: float = world._icon_view_scale()
	camera._tactical = true
	camera._blend = 1.0
	world._apply_view_scale(camera.view_scale())
	var tactical: float = world._icon_view_scale()
	check("the tactical view draws the icon tactical_icon_size of its follow-view size on screen",
		is_equal_approx(tactical / camera.view_scale(), follow * world.tactical_icon_size),
		"follow %.3f, tactical %.3f at view scale %.2f" % [follow, tactical, camera.view_scale()])
	world.queue_free()
	await get_tree().process_frame
