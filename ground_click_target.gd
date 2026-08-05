extends StaticBody3D
## Attach to your ground/terrain collision body. Left-click on empty
## ground clears the current selection (unless a ground-point-targeting
## ability like Jump is armed — see below); right-click issues a move
## order to the selected unit(s) toward the clicked point — UNLESS an
## ability is currently armed, in which case right-click disarms it
## instead (see _on_input_event) and does NOT also move, same as
## Unit._on_input_event's right-click handler for clicking a unit while
## armed. Right-click as "cancel the thing I just armed" is the natural
## expectation once arm/click-to-target exists at all — before this, an
## armed ability just silently swallowed the right-click and did
## nothing, which read as broken input rather than an intentional cancel.
##
## Requires:
##  - input_ray_pickable = true on this body (default is true)
##  - Project Settings > Physics > Common > Enable Object Picking = on
##    (default is on)
##
## "Left-click"/"right-click" above are the InputMap actions left_click/
## right_click (see project.godot > Input Map), not hardcoded
## MOUSE_BUTTON_LEFT/RIGHT checks — rebinding either needs no code change.

func _ready() -> void:
	input_event.connect(_on_input_event)


func _on_input_event(_camera: Node, event: InputEvent, click_position: Vector3, _normal: Vector3, _shape_idx: int) -> void:
	if event.is_action_pressed("left_click"):
		if _try_use_ground_targeted_ability(click_position):
			return
		SelectionManager.deselect_all()
	elif event.is_action_pressed("right_click"):
		if AbilityManager.armed_ability:
			AbilityManager.disarm()
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

	unit.use_ability(ability, click_position)
	return true


## Only reached when nothing's armed — see _on_input_event, which
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
	# carving for this one rebake, not just a single mover (see
	# NavigationCarving). Simultaneous movers can still end up navigating
	# around each other's stale (pre-move) positions rather than truly
	# live positions until the next rebake — an accepted approximation
	# outside combat, where "only one unit ever moves at a time" doesn't
	# hold in the first place.
	NavigationCarving.rebake_for_movers(get_tree(), SelectionManager.selected_units)
	for unit in SelectionManager.selected_units:
		unit.move_to(destination)
