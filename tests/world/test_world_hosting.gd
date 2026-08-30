extends AiTestCase
## A loaded world lives in its own viewport, and the player's attention
## nodes ride along into it.
##
## This is the half of rung 3b that the plan called untestable — a
## rendering-and-input move whose gate is "looks and feels identical."
## Most of that really is manual, but the structural claims underneath it
## are not, and they are the ones that silently rot: a world that ends up
## in the root World3D still renders fine and still plays fine TODAY,
## and only fails once a second world exists. Same no-op trap as rungs 2
## and 3a, one layer up.
##
## Drives the real WorldManager.load_area path rather than a stand-in,
## because the thing under test IS that path. The synthetic host stands in
## for MainRoot's own WorldHost, which this headless harness never builds.

var _host: Control
var _indicator: Node3D
var _saved_host: Control = null
var _saved_attention: Array[Node] = []


func run() -> void:
	if not _install_synthetic_host():
		check("SETUP: synthetic world host installed", false, "WorldManager refused")
		return

	await _a_loaded_world_gets_its_own_viewport()
	_attention_follows_the_world()
	await _unloading_returns_attention_home()

	_restore_host()


## WorldManager is an autoload shared with every other suite, so whatever
## it was holding is put back afterwards — see _restore_host.
func _install_synthetic_host() -> bool:
	_saved_host = WorldManager._world_host
	_saved_attention = WorldManager._attention_nodes.duplicate()

	_host = Control.new()
	_root.add_child(_host)
	WorldManager.register_world_host(_host)

	# One stand-in for MainRoot's Indicators/GroundClickTarget/
	# DialogueCameraRig — they are carried as a group, so one proves the
	# mechanism and keeps this suite from depending on MainRoot's layout.
	_indicator = Node3D.new()
	_root.add_child(_indicator)
	var attention: Array[Node] = [_indicator]
	WorldManager.register_attention_nodes(attention)

	return WorldManager.can_load()


func _a_loaded_world_gets_its_own_viewport() -> void:
	var world: Node = WorldManager.load_area(&"test_arena")
	await get_tree().process_frame

	check("the area loads", world != null and is_instance_valid(world))
	if world == null:
		return

	var viewport: Viewport = WorldManager.focused_viewport()
	check("and reports a focused viewport", viewport != null)
	if viewport == null:
		return

	check("the world sits inside that viewport",
		world.get_parent() == viewport)
	check("which is a SubViewport with a world of its own",
		viewport is SubViewport and (viewport as SubViewport).own_world_3d)

	# THE claim. A world in the root World3D plays perfectly well today and
	# fails the moment a second world exists — nothing else catches it.
	check("so the world is NOT in the root viewport's World3D",
		(world as Node3D).get_world_3d() != _root.get_world_3d(),
		"world shares the root World3D — residency would interleave them")

	check("and the world's context agrees on which World3D that is",
		WorldManager.context() != null
			and WorldManager.context().world_3d == (world as Node3D).get_world_3d())

	# Unit picking is per-viewport, and this is the setting that keeps
	# click-to-select working once the world stops rendering to the root.
	check("the viewport picks physics objects, so units stay clickable",
		(viewport as SubViewport).physics_object_picking)
	# Without a listener in the viewport that owns the world, every 3D
	# sound in it goes silent — a regression that makes no error at all.
	check("and carries a 3D audio listener",
		(viewport as SubViewport).audio_listener_enable_3d)

	check("the world's own camera is the focused camera",
		WorldManager.focused_camera() != null,
		"no camera reachable — HUD raycasts would all miss")


## An indicator left behind in MainRoot's World3D renders nothing and
## raycasts against nothing. It reports no error either way.
func _attention_follows_the_world() -> void:
	var viewport: Viewport = WorldManager.focused_viewport()
	if viewport == null:
		return

	check("the attention nodes moved into the world's viewport",
		_indicator.get_parent() == viewport,
		"left behind in %s" % _indicator.get_parent())
	check("so they share the world's World3D and can actually raycast it",
		_indicator.get_world_3d() == WorldManager.context().world_3d)


## They belong to the player, not the world, so they must survive it.
func _unloading_returns_attention_home() -> void:
	var unloaded: bool = WorldManager.unload()
	await get_tree().process_frame
	check("the world unloads", unloaded)

	check("the attention nodes outlive the world they were pointing at",
		is_instance_valid(_indicator),
		"freed along with the viewport")
	if is_instance_valid(_indicator):
		check("and go home rather than staying in a freed viewport",
			_indicator.get_parent() == _root)

	check("nothing is focused with no world loaded",
		WorldManager.focused_viewport() == null
			and WorldManager.focused_camera() == null)


func _restore_host() -> void:
	WorldManager._world_host = _saved_host
	WorldManager._attention_nodes = _saved_attention
	if is_instance_valid(_indicator):
		_indicator.queue_free()
	if is_instance_valid(_host):
		_host.queue_free()
