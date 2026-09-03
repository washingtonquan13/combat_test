extends AiTestCase
## The Cathedral of Shadows behaves as a room you are in but do not walk
## around, and its staging is where the cutscene expects to find it.
##
## The area is a diegetic menu: fusion happens in a place, in front of a
## device, rather than behind a screen. What makes that work is one
## override — spawns_party() false — plus marks an authored scene declares.
## Everything else about "no player control" follows: with nobody spawned
## there is nothing to select, command or move, and no system has to know
## this area is special.
##
## THE MARK HEIGHTS ARE THE POINT OF THE SECOND HALF. A proto_block is
## centred on its transform, so a mark placed at a platform's own origin
## sits INSIDE the stone — demons would fuse waist-deep in rock, on screen,
## and nothing else in the project would report it.

const AREA_ID := &"cathedral_of_shadows"
## Every platform is 10 tall and centred at y=5.5, so its top face is here.
const PLATFORM_TOP := 10.5


func run() -> void:
	var area: AreaDefinition = AreaDatabase.find(AREA_ID)
	if area == null or area.world_scene == null:
		check("SETUP: the cathedral is a registered area with a scene", false)
		return

	var room: Node = area.world_scene.instantiate()
	_root.add_child(room)
	await get_tree().process_frame

	# --- the control story ----------------------------------------------
	check("it is a GameArea",
		room is GameArea,
		"the scene root is %s, so none of the area contract applies" % room.get_class())

	check("and it spawns no party at all",
		room.has_method("spawns_party") and not room.spawns_party(),
		"the party would be projected into this room as tactical units, " +
		"which is exactly the control this area exists not to have")

	check("but it still offers somewhere to arrive",
		room.get_spawn_point(&"") != null,
		"no spawn point — WorldManager falls back to a marker named " +
		"'default' that does not exist, and arrivals land at the origin")

	# --- the staging the cutscene looks for ------------------------------
	var wanted: Array[StringName] = [
		FusionCinematic.DEVICE_MARK, FusionCinematic.LEFT_MARK,
		FusionCinematic.RIGHT_MARK, FusionCinematic.RESULT_MARK,
	]
	var missing: Array[String] = []
	var sunken: Array[String] = []
	for mark_name in wanted:
		var mark := room.find_child(String(mark_name), true, false) as Node3D
		if mark == null:
			missing.append(String(mark_name))
			continue
		if not mark.is_in_group(SceneCast.MARK_GROUP):
			missing.append("%s (not in the %s group)" % [mark_name, SceneCast.MARK_GROUP])
			continue
		if mark.global_position.y < PLATFORM_TOP - 0.01:
			sunken.append("%s at y=%.2f" % [mark_name, mark.global_position.y])

	check("every mark the fusion cutscene names exists here",
		missing.is_empty(),
		"missing: %s — the scene would push_error and stage nothing" % ", ".join(missing))

	check("and they sit on top of the platforms, not inside them",
		sunken.is_empty(),
		"%s, below the platform top at y=%.2f — a demon placed there is " % [
			", ".join(sunken), PLATFORM_TOP] +
		"standing in the stone")

	check("its base mode is FACILITY, not EXPLORATION",
		room.get_base_mode() == GameMode.Mode.FACILITY,
		"reports %s — a menu-room whose mode grants camera control has the " % 
			GameMode.Mode.keys()[room.get_base_mode()] +
		"menu and the pan fighting each other")

	room.queue_free()
	await get_tree().process_frame
	await _the_camera_yields_to_the_menu()
	_main_root_actually_carries_the_menu()
	await _fusing_somewhere_with_no_staging_still_fuses()


## The whole reason FACILITY exists as its own mode.
##
## A pushed UIScreen deliberately does NOT take camera control — UIScreen's
## own header says so and calls that integration separate, later work. So
## the only thing that stops WASD panning the camera behind an open menu is
## the base mode, and this is the assertion that says it does.
func _the_camera_yields_to_the_menu() -> void:
	var saved_host: Control = WorldManager._world_host
	var saved_attention: Array[Node] = WorldManager._attention_nodes.duplicate()
	var host := Control.new()
	_root.add_child(host)
	WorldManager.register_world_host(host)
	var none: Array[Node] = []
	WorldManager.register_attention_nodes(none)

	if not WorldManager.can_travel():
		check("SETUP: a synthetic host that can hold the room", false)
		WorldManager._world_host = saved_host
		WorldManager._attention_nodes = saved_attention
		host.queue_free()
		return

	# The harness never loads MainRoot, so the menu it normally finds is not
	# here. Instanced directly, which also proves the screen declares its
	# own group rather than relying on whoever placed it.
	var menu_scene: PackedScene = load("res://ui/cathedral_menu.tscn")
	var menu_instance: Control = menu_scene.instantiate()
	_root.add_child(menu_instance)

	WorldManager.load_area(AREA_ID)
	await get_tree().process_frame

	check("standing in it, the game reports FACILITY",
		GameMode.current_mode() == GameMode.Mode.FACILITY,
		"mode is %s" % GameMode.Mode.keys()[GameMode.current_mode()])

	check("and the tactical camera has no control there",
		not CameraDirector.has_control(),
		"the player can still pan the battlefield camera in a room whose " +
		"only interaction is a list")

	# The menu is the room's ONLY interface. Nothing else asserted it
	# actually appears, and it silently did not: the node was dropped from
	# MainRoot.tscn by an editor rescan rewriting the scene from a stale
	# copy, the suite stayed green, and the room shipped showing the
	# tactical HUD instead. A room whose interface is missing is a room you
	# cannot leave.
	var menu := get_tree().get_first_node_in_group(&"cathedral_menu") as CathedralMenu
	check("entering the room puts its menu on screen",
		menu != null and menu.is_visible_in_tree(),
		"the menu was never presented, so the room shows the ordinary HUD " +
		"and offers no way out")

	# THE PLAYER'S ACTUAL ROUTE. The check above loads the cathedral from
	# nothing, which is not how anyone reaches it — arriving from another
	# world runs _leave_focused() first, and that calls UIStack.close_all().
	# And leaving and coming back re-enters a RESIDENT world, which does not
	# run the area's _ready() again at all.
	WorldManager.load_area(&"overworld")
	await get_tree().process_frame
	WorldManager.load_area(AREA_ID)
	await get_tree().process_frame
	check("arriving from another world still shows the menu",
		menu_instance.is_visible_in_tree(),
		"the menu is not on screen after travelling in from the overworld")

	WorldManager.load_area(&"overworld")
	await get_tree().process_frame
	WorldManager.load_area(AREA_ID)
	await get_tree().process_frame
	check("and so does coming back a second time",
		menu_instance.is_visible_in_tree(),
		"the menu is missing on re-entry — a resident world is re-focused " +
		"rather than rebuilt, so the area's _ready() never runs again")

	menu_instance.queue_free()
	WorldManager.discard_worlds()
	WorldManager._world_host = saved_host
	WorldManager._attention_nodes = saved_attention
	host.queue_free()


## MainRoot actually carries the menu node.
##
## READ AS TEXT, not instantiated, for the same reason
## test_a_save_can_find_every_definition reads definitions as text: booting
## MainRoot inside a test would re-run its registrations against the live
## autoloads. And a behavioural check cannot cover this — the harness never
## loads MainRoot, so the group is empty there whether or not the node
## exists.
##
## This is not hypothetical. The node was added, verified present, and then
## silently dropped when an editor rescan rewrote the scene from a stale
## copy. Every suite stayed green and the room shipped showing the tactical
## HUD with no way out.
func _main_root_actually_carries_the_menu() -> void:
	var file := FileAccess.open("res://MainRoot.tscn", FileAccess.READ)
	if file == null:
		check("SETUP: MainRoot.tscn can be read", false)
		return
	var text: String = file.get_as_text()
	file.close()
	check("MainRoot carries the cathedral menu",
		text.contains("cathedral_menu.tscn") and text.contains('name="CathedralMenu"'),
		"the menu node is not in MainRoot.tscn — an editor rescan rewriting " +
		"that scene from a stale copy silently drops externally-added nodes")


## The degradation that matters: fusing on the overworld, or anywhere with
## no device, must still fuse. A missing camera angle is not a reason to
## withhold something the player spent two demons on.
func _fusing_somewhere_with_no_staging_still_fuses() -> void:
	var saved: Dictionary = DemonRoster.save_state()

	var species_a: UnitDefinition = load("res://data/units/demons/test_pixie.tres")
	var species_b: UnitDefinition = load("res://data/units/demons/test_wolf.tres")
	var a: OwnedDemon = DemonRoster.recruit(species_a)
	var b: OwnedDemon = DemonRoster.recruit(species_b)

	var expected: UnitDefinition = FusionRitual.preview(a, b)
	if expected == null:
		check("SETUP: the two fixtures fuse into something", false)
		DemonRoster.load_state(saved)
		return

	var born: OwnedDemon = await FusionRitual.perform(a, b)

	check("a fusion with nowhere to stage a cutscene still happens",
		born != null and born.species == expected,
		"got %s, expected %s" % [
			"nothing" if born == null else born.species.display_name,
			expected.display_name])
	check("and it consumed both parents",
		not DemonRoster.is_owned(a) and not DemonRoster.is_owned(b),
		"a parent is still on the roster after being fused away")

	DemonRoster.load_state(saved)
