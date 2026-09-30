extends AiTestCase
## Phase 4: a conversation can be re-staged without a narrative file being
## touched, because the join lives somewhere else.
##
## This is the one structural thing the BG3 study concluded Larian got most
## right, and the one the supplied architecture markdown got wrong by
## hanging a `cinematic` field off the dialogue node. The cost of that
## mistake is not obvious until you want a line with no staging, or two
## stagings of one conversation, or a re-record that does not open a
## cinematic file.
##
## THE STRUCTURAL CHECK IS THE POINT. "Play the bound scene" is behaviour
## and easy; "a DialogueNode has nowhere to put a scene" is the property
## that keeps it true a year from now.

const NODE_ID := "test_bound_node"
const OTHER_ID := "test_unbound_node"
const StageFixture := preload("res://tests/fixtures/stage_fixture.gd")

var _conversation: Conversation = null
var _saved_camera: CinematicCamera = null
var _saved_scene_root: Node = null
var _camera: CinematicCamera = null
var _staging: DialogueStaging = null
var _played: Array[PackedScene] = []


func run() -> void:
	# --- the structural half --------------------------------------------
	var node := DialogueNode.new()
	var fields: PackedStringArray = []
	for property in node.get_property_list():
		if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			fields.append(property.name)
	var presentation: Array[String] = []
	for name in fields:
		if name.contains("cinematic") or name.contains("scene") or name.contains("timeline"):
			presentation.append(name)

	check("a dialogue node has nowhere to put a scene",
		presentation.is_empty(),
		"DialogueNode carries %s — presentation has leaked into the " % ", ".join(presentation) +
		"content resource, which is exactly what the binding exists to prevent")

	check("and the binding resource is where that join lives",
		ResourceLoader.exists("res://systems/cinematic_system/scene_binding.gd"),
		"no SceneBinding, so there is nowhere for the join to live instead")

	# --- the behavioural half --------------------------------------------
	await _a_bound_node_stages_its_own_scene()
	_cleanup()


func _a_bound_node_stages_its_own_scene() -> void:
	_saved_camera = CinematicDirector.camera()
	# No world here, so the bound scene mounts under the test root.
	_saved_scene_root = WorldManager._scene_root
	WorldManager.register_scene_root(_root)

	var speaker: Unit = spawn_brute(0.0, 0.0)
	var listener: Unit = spawn_brute(3.0, 0.0)
	await get_tree().process_frame

	_camera = CinematicCamera.new()
	_root.add_child(_camera)
	_staging = DialogueStaging.new()
	_root.add_child(_staging)
	await get_tree().process_frame

	# Bound in the test rather than on disk: a shipped binding file would
	# make every conversation in the game depend on this fixture.
	var staged: PackedScene = StageFixture.make(0.05)
	var binding := SceneBinding.new()
	binding.scenes = {NODE_ID: staged}
	_staging._bindings = binding

	CinematicDirector.scene_started.connect(_note)

	# A real conversation, opened on a node with nothing bound to it. Its
	# node narrates only an empty aside, which never stages anything, so
	# every line below is one this suite records itself, against whichever
	# node the conversation is on.
	_conversation = Conversation.new(_node_with_id(OTHER_ID), {"npc": speaker, "player": listener})
	check("SETUP: the conversation began",
		Conversations.begin(_conversation),
		"refused — something already holds the player's input")
	_played.clear()
	_conversation.record("npc", "Ordinary.")
	check("an unbound node gets the default conversation shot, framed directly",
		_played.is_empty() and _camera.is_framing(),
		"played %s, camera framing=%s — an ordinary line should frame the " % [
			str(_played), _camera.is_framing()] +
		"speaker with no scene at all")

	# A node with a scene bound to it.
	_conversation.current_node = _node_with_id(NODE_ID)
	_played.clear()
	_conversation.record("player", "Staged.")
	check("a bound node gets its own scene instead",
		_played == [staged],
		"played %s — the binding was not consulted" % str(_played))

	# And only once, however many lines that node has.
	_played.clear()
	_conversation.record("npc", "Still staged.")
	check("and it stages once per node, not once per line",
		not _played.has(staged),
		"the staged scene replayed mid-node — played %s" % str(_played))


func _node_with_id(id: String) -> DialogueNode:
	var node := DialogueNode.new()
	node.id = id
	return node


func _note(scene: PackedScene) -> void:
	_played.append(scene)


func _cleanup() -> void:
	if CinematicDirector.scene_started.is_connected(_note):
		CinematicDirector.scene_started.disconnect(_note)
	if _conversation:
		_conversation.end()
	CinematicDirector.abort()
	if is_instance_valid(_staging):
		_staging.queue_free()
	if is_instance_valid(_camera):
		_camera.release()
		_camera.queue_free()
	CinematicDirector.register_camera(_saved_camera)
	WorldManager._scene_root = _saved_scene_root
