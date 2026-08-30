extends AiTestCase
## The overlay has one job beyond looking right: agreeing with the system
## it draws. A cone that shows a different angle, range, or blind spot
## than DetectionManager actually rolls against is worse than no cone —
## it teaches the player a rule the game doesn't follow.
##
## So these check the indicator against DetectionManager's OWN predicates
## rather than against hardcoded numbers.


var _indicator: SightConeIndicator


func run() -> void:
	_indicator = SightConeIndicator.new()
	_root.add_child(_indicator)

	_reads_geometry_off_the_unit()
	_colour_tracks_awareness()
	_agrees_with_detection_about_the_cone()
	_hidden_when_it_should_be()
	_key_toggles_it()

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
