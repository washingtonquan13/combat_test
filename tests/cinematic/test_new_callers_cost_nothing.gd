extends AiTestCase
## Phase 3, and it is an experiment rather than a feature.
##
## THE QUESTION: does adding a caller cost anything? Everything built so
## far was built against fusion — the one scene the vocabulary was designed
## for — and phase 2 added three step types to serve it. That is legitimate
## (fusion genuinely creates and destroys actors) but it means nothing yet
## has shown that the NEXT caller is free. If an establishing shot or a
## fight's opening had needed its own step, the vocabulary would have been
## fitted too tightly to one scene, and that would have been the finding.
##
## So the load-bearing check here is not "the intro plays". It is that both
## new callers are composed entirely of step types that already existed.
##
## The second half is the flag, which is what stops an establishing shot
## from replaying every time the player walks back through a door.

const ARENA := &"test_arena"
const ENTRY_FLAG := "cinematic.entered.test_arena"

var _saved_host: Control = null
var _saved_attention: Array[Node] = []
var _saved_camera: CinematicCamera = null
var _saved_flags: Dictionary = {}
var _host: Control = null
var _camera: CinematicCamera = null
var _cues: CinematicCues = null
var _played: Array[StringName] = []


func run() -> void:
	# --- the acceptance criterion ---------------------------------------
	var area: AreaDefinition = AreaDatabase.find(ARENA)
	if area == null or area.world_scene == null:
		check("SETUP: the arena is a registered area", false)
		return
	var room: Node = area.world_scene.instantiate()
	_root.add_child(room)
	await get_tree().process_frame

	var arrival: CinematicScene = (room as GameArea).entry_scene
	check("an ordinary area declares an arrival scene",
		arrival != null,
		"test_arena has no entry_scene, so this phase demonstrates nothing")

	if arrival:
		var kinds: Array[String] = _step_kinds(arrival)
		check("and it needed NO step type that did not already exist",
			kinds == ["CameraShotStep"],
			"uses %s. Anything beyond CameraShotStep means the vocabulary " % ", ".join(kinds) +
			"was fitted to fusion and a new caller costs a new step")
		check("and every step in it can actually fire",
			arrival.unreachable_steps().is_empty(),
			"steps sit past the end of their phase")
	room.queue_free()
	await get_tree().process_frame

	# --- and it actually plays, once -------------------------------------
	if not await _stand_up():
		_cleanup()
		return

	FlagManager.clear_flag(ENTRY_FLAG)
	_played.clear()
	WorldManager.load_area(ARENA)
	await get_tree().process_frame

	check("arriving somewhere for the first time stages it",
		_played.has(&"test_arena_arrival"),
		"nothing played — played: %s" % str(_played))

	check("and arriving is remembered",
		FlagManager.has_flag(ENTRY_FLAG),
		"no flag, so the establishing shot replays on every visit")

	# Let it finish before leaving, so the second visit is not measuring an
	# abort.
	await _until_idle()

	_played.clear()
	WorldManager.load_area(&"test_area_2")
	await get_tree().process_frame
	WorldManager.load_area(ARENA)
	await get_tree().process_frame

	check("but coming back does not stage it again",
		not _played.has(&"test_arena_arrival"),
		"the establishing shot replayed on a return visit — played: %s" % str(_played))

	# --- the camera goes back --------------------------------------------
	await _until_idle()
	check("and the camera is handed back when the shot ends",
		not _camera.is_framing(),
		"the cinematic camera is still holding the shot after an " +
		"establishing beat, so the player never gets the view back")

	_cleanup()


## Every distinct SceneStep subclass a scene uses.
func _step_kinds(scene: CinematicScene) -> Array[String]:
	var kinds: Array[String] = []
	for phase in scene.phases:
		if phase == null:
			continue
		for step in phase.steps:
			if step == null:
				continue
			var kind: String = step.get_script().resource_path.get_file().get_basename()
			# spawn_actor_step -> SpawnActorStep
			var pretty: String = ""
			for part in kind.split("_"):
				pretty += part.capitalize()
			if not kinds.has(pretty):
				kinds.append(pretty)
	kinds.sort()
	return kinds


func _note(scene: CinematicScene) -> void:
	_played.append(scene.id)


## Capped by FRAMES, not by accumulated delta. A headless frame's delta is
## whatever the machine managed, so a seconds budget is not a bound at all
## — this loop hung the whole suite before it was counted in frames.
func _until_idle(frames: int = 2000) -> void:
	var spent: int = 0
	while CinematicDirector.is_active() and spent < frames:
		await get_tree().process_frame
		spent += 1


func _stand_up() -> bool:
	_saved_host = WorldManager._world_host
	_saved_attention = WorldManager._attention_nodes.duplicate()
	_saved_camera = CinematicDirector.camera()
	_saved_flags = FlagManager.save_state()

	_host = Control.new()
	_root.add_child(_host)
	WorldManager.register_world_host(_host)
	var none: Array[Node] = []
	WorldManager.register_attention_nodes(none)

	_camera = CinematicCamera.new()
	_root.add_child(_camera)
	_cues = CinematicCues.new()
	_root.add_child(_cues)
	CinematicDirector.scene_started.connect(_note)
	await get_tree().process_frame
	return WorldManager.can_travel()


func _cleanup() -> void:
	if CinematicDirector.scene_started.is_connected(_note):
		CinematicDirector.scene_started.disconnect(_note)
	CinematicDirector.abort()
	if is_instance_valid(_cues):
		_cues.queue_free()
	if is_instance_valid(_camera):
		_camera.release()
		_camera.queue_free()
	WorldManager.discard_worlds()
	CinematicDirector.register_camera(_saved_camera)
	if not _saved_flags.is_empty():
		FlagManager.load_state(_saved_flags)
	# is_instance_valid, not a null check: a FREED Control is not null, and
	# assigning one to a typed field is a runtime error rather than a no-op.
	WorldManager._world_host = _saved_host if is_instance_valid(_saved_host) else null
	WorldManager._attention_nodes = _saved_attention
	if is_instance_valid(_host):
		_host.queue_free()
