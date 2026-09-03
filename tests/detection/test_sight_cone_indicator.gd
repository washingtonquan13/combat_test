extends AiTestCase
## The overlay has one job beyond looking right: agreeing with the system
## it draws. A cone that shows a different angle, range, or blind spot
## than DetectionManager actually rolls against is worse than no cone —
## it teaches the player a rule the game doesn't follow.
##
## So these check the indicator against DetectionManager's OWN predicates
## rather than against hardcoded numbers.
##
## wants_world(): true. _observers() gates on
## CombatManager.combat_running_in_world_of(self) (see sight_cone_indicator.gd)
## — a real per-world lookup keyed on the INDICATOR's own World3D, not just
## the units it draws for. The indicator is parented via _spawn_parent()
## rather than _root for exactly that reason: left under _root while a
## world is loaded, the indicator would sit in the SceneTree root's default
## World3D while the fight it should be hiding for runs in the fixture's
## own SubViewport World3D, and _hidden_when_it_should_be's "hidden during
## combat" check would pass for the wrong reason (or fail outright).
## _cones_stop_at_the_world_on_screen's own "elsewhere" SubViewport stays
## under _root — it is deliberately a THIRD, isolated world, not part of
## the loaded fixture.


var _indicator: SightConeIndicator


func wants_world() -> bool:
	return true


func run() -> void:
	_indicator = SightConeIndicator.new()
	_spawn_parent().add_child(_indicator)

	_reads_geometry_off_the_unit()
	_colour_tracks_awareness()
	_agrees_with_detection_about_the_cone()
	_hidden_when_it_should_be()
	_key_toggles_it()

	await _cones_stop_at_the_world_on_screen()

	_indicator.queue_free()


## Nothing about the drawn shape may be a duplicated constant.
func _reads_geometry_off_the_unit() -> void:
	var watcher: Unit = spawn_unit(&"enemy", 10, 12, 20, [melee()], Vector3.ZERO)
	watcher.vision_cone_degrees = 90.0
	watcher.max_sight_range = 11.0
	watcher.proximity_radius = 3.0

	check("cone angle comes from the unit", watcher.vision_cone_degrees == 90.0)
	check("cone radius comes from the unit", watcher.max_sight_range == 11.0)
	check("the blind-spot ring comes from the unit", watcher.proximity_radius == 3.0)
	free_spawned()


func _colour_tracks_awareness() -> void:
	var watcher: Unit = spawn_unit(&"enemy", 10, 12, 20, [melee()], Vector3.ZERO)
	var target: Unit = spawn_unit(&"player", 10, 12, 20, [melee()], Vector3(0.0, 0.0, -4.0))

	check("unaware reads as the calm colour",
		_indicator._color_for(watcher) == _indicator.unaware_color)

	watcher.awareness().notice(target, false)
	check("suspicious reads as the warning colour",
		_indicator._color_for(watcher) == _indicator.suspicious_color)

	watcher.awareness().notice(target, true)
	check("aware reads as the alarmed colour",
		_indicator._color_for(watcher) == _indicator.aware_color)
	free_spawned()


## The important one. For a spread of bearings, "is this inside the drawn
## wedge" and "does DetectionManager consider this inside the cone" must
## give the same answer every time.
func _agrees_with_detection_about_the_cone() -> void:
	var watcher: Unit = spawn_unit(&"enemy", 10, 12, 20, [melee()], Vector3.ZERO)
	var probe: Unit = spawn_unit(&"player", 10, 12, 20, [melee()], Vector3(0.0, 0.0, -5.0))
	watcher.vision_cone_degrees = 120.0
	watcher.snap_face_point(Vector3(0.0, 0.0, -50.0))

	var disagreements: PackedStringArray = []
	for step in 24:
		var bearing: float = (float(step) / 24.0) * TAU
		# Inside max_sight_range and outside proximity_radius, so the cone
		# is the only thing that can decide it either way.
		probe.global_position = Vector3(sin(bearing), 0.0, cos(bearing)) * 8.0

		var detection_says: bool = DetectionManager._within_cone(watcher, probe)
		var drawing_says: bool = _drawn_cone_contains(watcher, probe.global_position)
		if detection_says != drawing_says:
			disagreements.append("%.0f deg" % rad_to_deg(bearing))

	check("the drawn wedge matches the cone detection actually uses",
		disagreements.is_empty(),
		"disagreed at: %s" % ", ".join(disagreements))
	free_spawned()


## Same maths the indicator uses to lay out its arc, applied as a
## containment test — if _draw_cone's geometry drifts from
## DetectionManager's, this is what catches it.
func _drawn_cone_contains(observer: Unit, point: Vector3) -> bool:
	var to_point: Vector3 = point - observer.global_position
	to_point.y = 0.0
	if to_point.length() > observer.max_sight_range:
		return false

	var forward: Vector3 = observer.visual_forward()
	forward.y = 0.0
	if forward.length() < 0.01 or to_point.length() < 0.01:
		return true

	var half_angle: float = observer.vision_cone_degrees * 0.5
	return rad_to_deg(forward.normalized().angle_to(to_point.normalized())) <= half_angle


## The overlay is a development view, so it needs to be dismissible
## without editing a scene — same family as F3's nav overlay.
func _key_toggles_it() -> void:
	check("the toggle action exists in the input map",
		InputMap.has_action("toggle_sight_cones"))

	var watcher: Unit = spawn_unit(&"enemy", 10, 12, 20, [melee()], Vector3.ZERO)
	var player: Unit = spawn_unit(&"player", 10, 12, 20, [melee()], Vector3(0.0, 0.0, -4.0))

	var started_enabled: bool = _indicator.enabled
	var press := InputEventAction.new()
	press.action = "toggle_sight_cones"
	press.pressed = true
	_indicator._unhandled_input(press)
	check("pressing it flips the overlay off", _indicator.enabled != started_enabled)
	_indicator._unhandled_input(press)
	check("and pressing it again flips it back", _indicator.enabled == started_enabled)

	free_spawned()


func _hidden_when_it_should_be() -> void:
	var watcher: Unit = spawn_unit(&"enemy", 10, 12, 20, [melee()], Vector3.ZERO)
	var player: Unit = spawn_unit(&"player", 10, 12, 20, [melee()], Vector3(0.0, 0.0, -4.0))

	check("draws a cone for a non-player unit out of combat",
		_indicator._observers().has(watcher))
	check("never draws one for a party member",
		not _indicator._observers().has(player))

	_indicator.enabled = false
	check("the master switch turns everything off", _indicator._observers().is_empty())
	_indicator.enabled = true

	var roster: Array[Unit] = [watcher, player]
	CombatManager.start_combat(roster)
	check("hidden during combat, where everyone already knows where everyone is",
		_indicator._observers().is_empty())
	CombatManager.end_combat(&"")

	free_spawned()


## Cones are drawn for observers found through UnitQuery.living_units,
## which is the deliberately GLOBAL form and spans every RESIDENT world
## rather than the one on screen. Unscoped, an NPC standing in an area
## the player cannot see had its field of view drawn over the area they
## can — a cone hanging in the air above unrelated ground.
##
## Built with two live World3Ds the way tests/world does, since a
## one-world game cannot tell a scoped query from an unscoped one.
func _cones_stop_at_the_world_on_screen() -> void:
	var elsewhere := SubViewport.new()
	elsewhere.own_world_3d = true
	elsewhere.size = Vector2i(64, 64)
	_root.add_child(elsewhere)
	await get_tree().process_frame

	var foreign: Unit = load("res://systems/unit_system/unit.tscn").instantiate()
	elsewhere.add_child(foreign)
	foreign.faction = &"enemy"
	foreign.strength = 10
	foreign.dexterity = 10
	foreign.maximum_hp = 20
	foreign.current_hp = 20
	var abilities: Array[Ability] = [melee()]
	foreign.abilities = abilities
	foreign.global_position = Vector3.ZERO
	foreign.reset_turn_actions()
	await get_tree().physics_frame

	# A party member in THIS world, so _observers has someone to be
	# hostile to — without one it returns empty and the check below would
	# pass without testing anything.
	var ally: Unit = spawn_brute(4.0)
	ally.faction = &"player"
	await get_tree().physics_frame

	var observers: Array[Unit] = _indicator._observers()
	check("an NPC in another world gets no cone drawn in this one",
		not observers.has(foreign),
		"a foreign observer leaked into the overlay")

	if foreign.is_in_group("units"):
		foreign.remove_from_group("units")
	elsewhere.remove_child(foreign)
	foreign.queue_free()
	_root.remove_child(elsewhere)
	elsewhere.queue_free()
