extends "res://tools/fog_cloud_demo.gd"
## Recorded tour of the ground surfaces' looks, for judging them - NOT a
## test. Each scene is placed by hand (they have no abilities yet), seen
## all together, then up close one by one, then expired.

const LOOKS: Array[PackedScene] = [
	preload("res://systems/surface_system/grease.tscn"),
	preload("res://systems/surface_system/water.tscn"),
	preload("res://systems/surface_system/blood.tscn"),
	preload("res://systems/surface_system/acid.tscn"),
	preload("res://systems/surface_system/ice.tscn"),
	preload("res://systems/surface_system/web.tscn"),
	preload("res://systems/surface_system/fire.tscn"),
]

var _yaw: float = NAN


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.deselect_all()
	var centre: Vector3 = _spot(-12.0, 0.0)
	_frame(centre, 22.0)
	await _wait(2.0)
	var placed: Array[Node3D] = []
	for i in LOOKS.size():
		var row: int = i / 4
		var column: float = i % 4 - (1.5 if row == 0 else 1.0)
		var look: Node3D = LOOKS[i].instantiate()
		WorldManager.spawn_parent().add_child(look)
		look.global_position = _spot(-12.0 + (row - 0.5) * 5.5, column * 5.5)
		look.scale = Vector3(2.0, 1.0, 2.0)
		placed.append(look)
		_say(look.name)
		await _wait(0.4)
	await _wait(2.5)
	for look in placed:
		_say(look.name)
		_frame(look.global_position, 6.0)
		await _wait(3.0)
	_frame(centre, 22.0)
	await _wait(1.5)
	_say("Surfaces expire")
	for look in placed:
		look.dissipate()
	await _wait(3.0)
	print("DEMO RESULT: done")
	get_tree().quit()


## fog_cloud_demo's framing, but holding one heading for the whole tour.
func _frame(point: Vector3, distance: float) -> void:
	super(point, distance)
	var camera: CRPGCamera = get_tree().root.find_children("*", "CRPGCamera", true, false)[0]
	if is_nan(_yaw):
		_yaw = camera.target_yaw
	camera.target_yaw = _yaw
