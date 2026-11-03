extends "res://tools/fog_cloud_demo.gd"
## Recorded tour of the ground surfaces' looks, for judging them - NOT a
## test. Each is spilled from a stand-in Surface (they have no abilities
## yet), seen all together, then up close one by one, then expired.

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
	var spots: Array[Vector3] = []
	for i in LOOKS.size():
		var row: int = i / 4
		var column: float = i % 4 - (1.5 if row == 0 else 1.0)
		var at: Vector3 = _spot(-12.0 + (row - 0.5) * 5.5, column * 5.5)
		var patch: SurfacePatch = SurfaceManager.spawn(_ground(LOOKS[i]), at, 2.0, _hero)
		spots.append(at)
		_say(patch.visual.name)
		await _wait(0.4)
	await _wait(2.5)
	for i in spots.size():
		_say(LOOKS[i].resource_path.get_file().get_basename().capitalize())
		_frame(spots[i], 6.0)
		await _wait(3.0)
	_frame(centre, 22.0)
	await _wait(1.5)
	_say("Surfaces expire")
	SurfaceManager.expire_all_ground(WorldManager.context())
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


## A lasting ground Surface that looks like look.
func _ground(look: PackedScene) -> Surface:
	var surface := Surface.new()
	surface.shape = Surface.Shape.DISC
	surface.duration_rounds = -1
	surface.ambient_scene = look
	return surface
