extends Node
## Standalone walkthrough — NOT a test, NOT part of tests/run.sh.
## Shows what a dialogue's stand-ins do (see StandIn, SceneTemplate). Boots
## the real game into the quarry and talks to the Scared Townperson twice,
## from two different places the hero might have stopped. A second camera
## looks down on the pair the whole time: red rings mark where the two units
## really are. Before and after each talk that view fills the screen; during
## it, it sits in the corner while the game's own dialogue shots play.
##
##   Godot --resolution 1600x900 --write-movie <out.avi> --fixed-fps 30 res://tools/stand_in_demo.tscn

const MainRootScene: PackedScene = preload("res://MainRoot.tscn")
const HERO: UnitDefinition = preload("res://data/units/npcs/proof_hero.tres")
const NPC_NAME := "Scared Townperson"
const LINE_SECONDS := 3.0
const LINES_PER_TALK := 3
## Where the hero stops, as (metres ahead of the npc, metres to its side),
## and the way the hero is left facing, in degrees off "at the npc".
const STOPS: Array = [
	{"ahead": 0.9, "side": -1.6, "turned": 70.0, "name": "Stop 1: off to one side, half turned away"},
	{"ahead": 1.9, "side": 0.25, "turned": 180.0, "name": "Stop 2: straight ahead, too far, back turned"},
]

var _caption: Label
var _truth: TextureRect
var _truth_frame: Panel
var _truth_label: Label
var _overhead: Camera3D
var _rings: Array[MeshInstance3D] = []


func _ready() -> void:
	add_child(MainRootScene.instantiate())
	_run.call_deferred()


func _run() -> void:
	await _wait(1.0)
	get_tree().get_first_node_in_group("main_menu")._on_start_pressed()
	await _wait(1.0)
	var creation: Node = get_tree().get_first_node_in_group("character_creation")
	creation._on_auto_fill_pressed()
	await _wait(0.5)
	creation._on_confirm_pressed()
	await WorldManager.world_focused
	await _wait(2.0)

	var npc: Unit = WorldManager.spawn_parent().find_child(NPC_NAME, true, false) as Unit
	if npc == null:
		print("DEMO: no ", NPC_NAME)
		get_tree().quit(1)
		return
	var hero: Unit = HERO.unit_scene.instantiate()
	hero.definition = HERO
	WorldManager.spawn_parent().add_child(hero)
	var ahead: Vector3 = npc.visual_forward()
	ahead.y = 0.0
	ahead = ahead.normalized()
	var side: Vector3 = ahead.cross(Vector3.UP)

	_build_overlay(npc, ahead)
	_rings = [_ring(), _ring()]

	for stop in STOPS:
		hero.global_position = npc.global_position + ahead * stop.ahead + side * stop.side
		var to_npc: Vector3 = (npc.global_position - hero.global_position).normalized()
		hero.snap_face_point(hero.global_position + to_npc.rotated(Vector3.UP, deg_to_rad(stop.turned)))
		_rings[0].global_position = hero.global_position + Vector3.UP * 0.03
		_rings[1].global_position = npc.global_position + Vector3.UP * 0.03

		_fill(true)
		_say("%s\nRed rings: where the game has the two units." % stop.name)
		await _wait(4.0)
		# Measured from here, once the placed hero has settled on the ground.
		_rings[0].global_position = hero.global_position + Vector3.UP * 0.03
		var hero_was: Transform3D = hero.global_transform
		var npc_was: Transform3D = npc.global_transform

		var cast := {"player": hero, "npc": npc, "leader": hero}
		var root: DialogueNode = npc.resolve_dialogue_root(Conversation.new(null, cast))
		var c: Conversation = TalkInteraction.start(root, cast)
		if c == null:
			print("DEMO: the conversation was refused")
			get_tree().quit(1)
			return
		print("DEMO talk starts at movie second %.2f" % (Engine.get_frames_drawn() / 30.0))
		_fill(false)
		_say("Talk begins. A copy of each stands on the template's marks; their own bodies are hidden.\nThe units have not moved: the rings are still where they are.")
		print("DEMO stand-ins: hero ", StandIn.of(hero) != null, " npc ", StandIn.of(npc) != null)
		await _talk(c)
		for pair in [[hero, hero_was], [npc, npc_was]]:
			var now: Transform3D = (pair[0] as Unit).global_transform
			var was: Transform3D = pair[1]
			print("DEMO drift ", pair[0].name, ": moved %.4f m, turned %.2f deg" % [
				now.origin.distance_to(was.origin),
				rad_to_deg(now.basis.get_rotation_quaternion().angle_to(was.basis.get_rotation_quaternion()))])
		print("DEMO units unmoved during talk: ",
			hero.global_transform.is_equal_approx(hero_was) and npc.global_transform.is_equal_approx(npc_was))
		if not c.ended:
			c.end()
		_fill(true)
		_say("Talk ends. The copies are gone and the bodies are back, exactly where they were.")
		await _wait(4.0)
		print("DEMO units unmoved after talk: ",
			hero.global_transform.is_equal_approx(hero_was) and npc.global_transform.is_equal_approx(npc_was),
			", stand-ins gone: ", StandIn.of(hero) == null and StandIn.of(npc) == null)

	_say("Two different stops, the same shots.")
	await _wait(2.5)
	print("DEMO done")
	get_tree().quit()


## Lets a few lines play, taking the first choice whenever one is offered.
func _talk(c: Conversation) -> void:
	var seen := 0
	var idle := 0.0
	var lines := 0
	while not c.ended and lines < LINES_PER_TALK:
		await get_tree().process_frame
		if c.transcript.size() > seen:
			seen = c.transcript.size()
			lines += 1
			await _wait(LINE_SECONDS)
			if lines >= LINES_PER_TALK:
				return
			var skip := InputEventAction.new()
			skip.action = &"cinematic_advance"
			skip.pressed = true
			Input.parse_input_event(skip)
			idle = 0.0
			continue
		var snap: Dictionary = c.snapshot()
		if not snap.waiting.is_empty() or snap.busy:
			idle = 0.0
			continue
		idle += get_process_delta_time()
		if idle < 1.5:
			continue
		idle = 0.0
		if snap.choices.is_empty():
			return
		c.choose(snap.choices[0].id)


func _build_overlay(npc: Unit, ahead: Vector3) -> void:
	var view := SubViewport.new()
	view.size = Vector2i(1600, 900)
	view.world_3d = npc.get_world_3d()
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(view)
	_overhead = Camera3D.new()
	_overhead.fov = 40.0
	# Its own plain light and exposure: the area's fog is tuned for the
	# game's cameras and whites this one out.
	var plain := Environment.new()
	plain.background_mode = Environment.BG_COLOR
	plain.background_color = Color(0.5, 0.6, 0.7)
	plain.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	plain.ambient_light_color = Color.WHITE
	plain.ambient_light_energy = 0.6
	plain.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_overhead.environment = plain
	_overhead.attributes = CameraAttributesPractical.new()
	# XRaySilhouettes' full-screen capture quad is on this layer.
	_overhead.cull_mask &= ~(1 << (XRaySilhouettes.CAPTURE_LAYER - 1))
	view.add_child(_overhead)
	var centre: Vector3 = npc.global_position + ahead * 0.7 + Vector3.UP * 0.9
	var side: Vector3 = ahead.cross(Vector3.UP)
	_overhead.look_at_from_position(centre + Vector3.UP * 4.6 + ahead * 2.2 + side * 3.2, centre, Vector3.UP)
	_overhead.current = true

	var layer := CanvasLayer.new()
	layer.layer = 100
	add_child(layer)
	_truth_frame = Panel.new()
	var border := StyleBoxFlat.new()
	border.bg_color = Color.BLACK
	border.set_border_width_all(3)
	border.border_color = Color(1, 1, 1, 0.85)
	_truth_frame.add_theme_stylebox_override("panel", border)
	layer.add_child(_truth_frame)
	_truth = TextureRect.new()
	_truth.texture = view.get_texture()
	_truth.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_truth.stretch_mode = TextureRect.STRETCH_SCALE
	layer.add_child(_truth)
	_truth_label = Label.new()
	_truth_label.text = "WHERE THE UNITS REALLY ARE"
	_truth_label.add_theme_font_size_override("font_size", 16)
	_truth_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_truth_label.add_theme_constant_override("outline_size", 6)
	layer.add_child(_truth_label)

	_caption = Label.new()
	_caption.position = Vector2(28, 20)
	_caption.add_theme_font_size_override("font_size", 26)
	_caption.add_theme_color_override("font_outline_color", Color.BLACK)
	_caption.add_theme_constant_override("outline_size", 10)
	layer.add_child(_caption)


## The look-down view over the whole screen, or tucked into the top right.
func _fill(whole: bool) -> void:
	var screen: Vector2 = get_viewport().get_visible_rect().size
	var rect := Rect2(Vector2.ZERO, screen) if whole \
			else Rect2(Vector2(screen.x - 560 - 24, 110), Vector2(560, 315))
	_truth.position = rect.position
	_truth.size = rect.size
	_truth_frame.position = rect.position - Vector2(3, 3)
	_truth_frame.size = rect.size + Vector2(6, 6)
	_truth_frame.visible = not whole
	_truth_label.visible = not whole
	_truth_label.position = rect.position + Vector2(10, 6)


func _say(text: String) -> void:
	_caption.text = text
	print("DEMO caption: ", text.replace("\n", " / "))


func _ring() -> MeshInstance3D:
	var ring := MeshInstance3D.new()
	var mesh := TorusMesh.new()
	mesh.inner_radius = 0.36
	mesh.outer_radius = 0.44
	ring.mesh = mesh
	var paint := StandardMaterial3D.new()
	paint.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	paint.albedo_color = Color(1.0, 0.15, 0.1)
	paint.no_depth_test = true
	ring.material_override = paint
	ring.scale = Vector3(1, 0.15, 1)
	WorldManager.spawn_parent().add_child(ring)
	return ring


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
