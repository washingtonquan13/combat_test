extends AiTestCase
## The overworld's tactical view (camera_tactical, BG3's top-down map
## view) looks down from far above, so everything sized for the follow
## view grows with the camera's distance: the distance haze moves out, the
## camera sees farther, the avatar's icon stays the same size on screen.
## Toggling back puts every one of them back exactly as authored.
##
## Driven through the camera's own input handler with the real action,
## on the real overworld scene.

const HOME := &"test_arena"
const OVERWORLD := &"overworld"

var _host: Control
var _saved_host: Control = null
var _saved_attention: Array[Node] = []
var _snapshot: Dictionary = {}


func run() -> void:
	if not _install_synthetic_host():
		check("SETUP: synthetic world host installed", false)
		_restore()
		return
	_snapshot_globals()
	PartyManager.clear_members()
	PartyManager.load_state({})
	WorldManager.load_area(HOME)
	await get_tree().process_frame
	WorldManager.load_area(OVERWORLD)
	await _wait(0.5)

	var world: Node = WorldManager.current_world()
	var camera: OverworldCamera = world.get_node_or_null(^"OverworldCamera") if world else null
	var env: Environment = world._environment.environment if world and world._environment else null
	var avatar: Node3D = world._active_avatar() if world else null
	if camera == null or env == null or avatar == null:
		check("SETUP: overworld camera, environment and avatar", false)
		_restore()
		return
	var fog_end := env.fog_depth_end
	var far := camera.far
	var icon: Vector3 = avatar._spin_pivot.scale
	var pitch := camera.rotation.x

	_toggle(camera)
	await _wait(camera.tactical_blend_time + 0.3)
	var f := camera.view_scale()
	check("the tactical view is farther out", camera.is_tactical() and f > 2.0, "view scale %.2f" % f)
	check("and looks down", rad_to_deg(-camera.rotation.x) > 75.0,
		"pitch %.1f degrees" % rad_to_deg(-camera.rotation.x))
	check("the haze moves out with it", is_equal_approx(env.fog_depth_end, fog_end * f),
		"fog end %.0f, follow view %.0f, scale %.2f" % [env.fog_depth_end, fog_end, f])
	check("the camera sees as far", is_equal_approx(camera.far, far * f), "far %.0f" % camera.far)
	check("the avatar's icon grows to stay the same size on screen",
		avatar._spin_pivot.scale.is_equal_approx(icon * f), "scale %s" % avatar._spin_pivot.scale)

	_toggle(camera)
	await _wait(camera.tactical_blend_time + 0.3)
	check("toggling back puts the haze back", is_equal_approx(env.fog_depth_end, fog_end),
		"fog end %.0f, authored %.0f" % [env.fog_depth_end, fog_end])
	check("and the camera, pitch and icon", is_equal_approx(camera.far, far)
		and is_equal_approx(camera.rotation.x, pitch) and avatar._spin_pivot.scale.is_equal_approx(icon),
		"far %.0f, pitch %.1f, scale %s" % [camera.far, rad_to_deg(-camera.rotation.x), avatar._spin_pivot.scale])
	_restore()


func _toggle(camera: OverworldCamera) -> void:
	var ev := InputEventAction.new()
	ev.action = &"camera_tactical"
	ev.pressed = true
	camera._unhandled_input(ev)


func _wait(seconds: float) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame


func _install_synthetic_host() -> bool:
	_saved_host = WorldManager._world_host
	_saved_attention = WorldManager._attention_nodes.duplicate()
	_host = Control.new()
	_root.add_child(_host)
	WorldManager.register_world_host(_host)
	var none: Array[Node] = []
	WorldManager.register_attention_nodes(none)
	return WorldManager.can_travel()


func _snapshot_globals() -> void:
	_snapshot = {
		"flags": FlagManager.save_state(),
		"party": PartyManager.save_state(),
		"demons": DemonRoster.save_state(),
		"currency": CurrencyManager.save_state(),
	}


func _restore() -> void:
	WorldManager.discard_worlds()
	if not _snapshot.is_empty():
		FlagManager.load_state(_snapshot["flags"])
		PartyManager.load_state(_snapshot["party"])
		DemonRoster.load_state(_snapshot["demons"])
		CurrencyManager.load_state(_snapshot["currency"])
	while PartyManager.groups.size() > 1:
		PartyManager.groups[0].absorb(PartyManager.groups[1])
		PartyManager.groups.remove_at(1)
	if not PartyManager.groups.is_empty():
		PartyManager.active_group = PartyManager.groups[0]
	WorldManager._world_host = _saved_host
	WorldManager._attention_nodes = _saved_attention
	if is_instance_valid(_host):
		_host.queue_free()
