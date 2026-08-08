extends IndicatorBase
## Global ground-click handler — left-click on empty ground clears the
## current selection (unless a ground-point-targeting ability like Jump
## is armed — see below); right-click issues a move order to the
## selected unit(s) toward the clicked point — UNLESS an ability is
## currently armed, in which case right-click disarms it instead and
## does NOT also move, same as Unit._on_input_event's right-click
## handler for clicking a unit while armed. Right-click as "cancel the
## thing I just armed" is the natural expectation once arm/click-to-
## target exists at all — before this, an armed ability just silently
## swallowed the right-click and did nothing, which read as broken
## input rather than an intentional cancel.
##
## One global node doing a centralized raycast (via IndicatorBase's
## _get_mouse_ground_point/_get_hovered_unit), NOT a script attached to
## every ground collision body — the previous version extended
## StaticBody3D and relied on per-object physics picking
## (CollisionObject3D.input_event), which meant this exact script had
## to be attached individually to all five of main.tscn's ground/
## platform bodies. That stops scaling the moment a real level's ground
## is built from more than a handful of pieces (a GridMap, a multi-
## chunk terrain, ...). This version needs to exist exactly once, and
## works against any number of ground bodies for free as long as they're
## on ground_collision_mask (see IndicatorBase) — no per-object setup.
##
## A hovered-unit check runs first and bails out if the click actually
## landed on a unit — Unit._on_input_event (still per-object physics
## picking, unchanged) already owns clicks landing on a unit; this
## script must not also react to the same click's ground point.
##
## "Left-click"/"right-click" below are the InputMap actions left_click/
## right_click (see project.godot > Input Map), not hardcoded
## MOUSE_BUTTON_LEFT/RIGHT checks — rebinding either needs no code change.

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("left_click"):
		if _get_hovered_unit():
			return
		var click_position = _get_mouse_ground_point()
		if click_position == null:
			return
		if _try_use_ground_targeted_ability(click_position):
			return
		SelectionManager.deselect_all()
	elif event.is_action_pressed("right_click"):
		if _get_hovered_unit():
			return
		if AbilityManager.armed_ability:
			AbilityManager.disarm()
			return
		var click_position = _get_mouse_ground_point()
		if click_position == null:
			return
		_command_move(click_position)


## If the currently armed ability (see AbilityManager) expects a ground
## point as its target (Ability.targeting.expects_point_target — Jump,
## an AoE, or any future point-targeting ability), and it's the acting
## player unit's own turn, uses it at the clicked point instead of the
## click falling through to normal ground-click behavior. Mirrors how
## Unit._on_input_event checks ability-use before falling through to
## normal selection on an enemy click — same pattern, applied to ground
## clicks instead of unit clicks. Returns true if the click was consumed
## this way.
func _try_use_ground_targeted_ability(click_position: Vector3) -> bool:
	var ability: Ability = AbilityManager.armed_ability
	if not ability or not ability.targeting or not ability.targeting.expects_point_target():
		return false

	var unit: Unit = PlayerInteractionState.get_active_unit()
	if not unit or unit not in SelectionManager.selected_units:
		return false

	# click_position is always exactly where the physics ray hit the
	# ground, so it can never carry a lifted height on its own — an
	# AerialAreaTargeting ability aimed into the air via
	# aerial_area_indicator.gd's Ctrl height-drag (see that file and
	# AbilityManager.aim_height_override) needs its Y overridden here,
	# the same value the preview was already showing, so the confirmed
	# cast can't disagree with what the player saw. Checked against
	# AerialAreaTargeting specifically, not AreaTargeting generally —
	# plain AreaTargeting (Grease) is floor-only by design (see that
	# class and area_indicator.gd) and must never pick up a stray
	# override. GroundPointTargeting (Jump) never gets one either — you
	# can't jump to a point floating in midair with nothing under it.
	var target_point: Vector3 = click_position
	if ability.targeting is AerialAreaTargeting and AbilityManager.has_aim_height_override:
		target_point.y = AbilityManager.aim_height_override

	unit.use_ability(ability, target_point)
	return true


## Only reached when nothing's armed — see _unhandled_input, which
## disarms and consumes the click instead of calling this whenever an
## ability IS armed.
func _command_move(destination: Vector3) -> void:
	if CombatManager.in_combat:
		# Only the acting unit may move, and only on its own turn — a
		# right-click while other units are selected (or it's not your
		# turn) is silently ignored rather than moving the wrong unit.
		var unit: Unit = CombatManager.current_unit
		if unit and unit in SelectionManager.selected_units:
			unit.move_to(destination)
		return

	# Free-roam moves aren't gated by turn order the way combat is — every
	# selected unit can move at once — so all of them are excluded from
	# occupancy for this one update, not just a single mover (see
	# NavigationGrid). Simultaneous movers can still end up navigating
	# around each other's stale (pre-move) positions rather than truly
	# live positions until the next update — an accepted approximation
	# outside combat, where "only one unit ever moves at a time" doesn't
	# hold in the first place.
	NavigationGrid.update_occupancy(get_tree(), SelectionManager.selected_units)
	for unit in SelectionManager.selected_units:
		unit.move_to(destination)
