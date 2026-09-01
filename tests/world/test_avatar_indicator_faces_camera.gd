extends AiTestCase
## The overworld avatar's alignment indicator rests pointing at the camera.
##
## The Neutral wobble is a yaw oscillation of SpinPivot, and it used to
## swing about the avatar's own zero — so where it sat depended entirely on
## which way the player had swung the camera. The indicator could rest
## behind the capsule and wobble out of sight, which is a poor showing for
## the one alignment whose whole reading is "not committed either way".
##
## Geometry, not looks. What is asserted is that the pivot's +X — where the
## indicator bar actually is, at x=0.45 in overworld_avatar.tscn — points
## at the camera once the facing yaw is applied. That is exactly the step
## with a sign in it, and a sign error here aims the bar directly AWAY from
## the viewer, which reads as plausible-but-wrong rather than as broken.
##
## Deliberately does not touch PartyManager or drive a real wobble: which
## alignment is showing, and the sine on top, are not what this is about.

const CARDINALS := [
	Vector3(6.0, 4.0, 0.0),
	Vector3(-6.0, 4.0, 0.0),
	Vector3(0.0, 4.0, 6.0),
	Vector3(0.0, 4.0, -6.0),
	Vector3(5.0, 9.0, -5.0),
]


func run() -> void:
	var avatar: OverworldAvatar = preload("res://overworld_avatar.tscn").instantiate()
	_root.add_child(avatar)
	var camera := OverworldCamera.new()
	_root.add_child(camera)
	avatar.camera = camera
	avatar.global_position = Vector3.ZERO
	await get_tree().process_frame

	var pivot: Node3D = avatar.get_node("SpinPivot")

	var worst: float = 0.0
	var worst_at: Vector3 = Vector3.ZERO
	for spot in CARDINALS:
		camera.global_position = spot
		pivot.rotation.y = avatar._yaw_facing_camera()
		# Forced, because nothing is running a frame between these.
		avatar.force_update_transform()
		pivot.force_update_transform()

		var bar: Vector3 = pivot.global_transform.basis.x
		var to_camera: Vector3 = camera.global_position - pivot.global_position
		var flat_bar := Vector2(bar.x, bar.z).normalized()
		var flat_to_camera := Vector2(to_camera.x, to_camera.z).normalized()
		var off_by: float = rad_to_deg(absf(flat_bar.angle_to(flat_to_camera)))
		if off_by > worst:
			worst = off_by
			worst_at = spot

	check("the indicator points at the camera from every angle",
		worst < 1.0,
		"off by %.1f degrees with the camera at %s — 180 means the sign is inverted and it is aiming out the back" % [
			worst, str(worst_at)])

	# A camera that was never assigned must not throw or spin the pivot to
	# somewhere arbitrary: the overworld assigns it right after instancing,
	# so there is a real window before it exists, plus every headless test.
	avatar.camera = null
	check("and no camera means no facing rotation, not an error",
		is_equal_approx(avatar._yaw_facing_camera(), 0.0))

	avatar.queue_free()
	camera.queue_free()
