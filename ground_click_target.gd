extends StaticBody3D
## Attach to your ground/terrain collision body. Left-click on empty
## ground clears the current selection (unless a ground-point-targeting
## ability like Jump is armed — see below); right-click issues a move
## order to the selected unit(s) toward the clicked point.
##
## Requires:
##  - input_ray_pickable = true on this body (default is true)
##  - Project Settings > Physics > Common > Enable Object Picking = on
##    (default is on)

func _ready() -> void:
	input_event.connect(_on_input_event)


func _on_input_event(_camera: Node, event: InputEvent, click_position: Vector3, _normal: Vector3, _shape_idx: int) -> void:
	if not (event is InputEventMouseButton and event.pressed):
		return

	if event.button_index == MOUSE_BUTTON_LEFT:
		if _try_use_ground_targeted_ability(click_position):
			return
		SelectionManager.deselect_all()
	elif event.button_index == MOUSE_BUTTON_RIGHT:
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


func _command_move(destination: Vector3) -> void:
	if CombatManager.in_combat:
		# Only the acting unit may move, and only on its own turn — a
		# right-click while other units are selected (or it's not your
		# turn) is silently ignored rather than moving the wrong unit.
		# Also silently ignored while an ability is armed — same rule
		# movement_indicator.gd already enforces visually (it hides
		# itself in this exact state), now actually enforced here too,
		# not just implied. Without this, right-clicking while something
		# was armed would move the unit anyway despite the indicator
		# having told the player movement wasn't on the table — arm and
		# move were never mutually exclusive in practice, just visually
		# implied to be. Uses PlayerInteractionState, the same shared
		# check the indicator itself uses, so the two can't drift apart.
		if PlayerInteractionState.has_any_ability_armed():
			return
		var unit: Unit = CombatManager.current_unit
		if unit and unit in SelectionManager.selected_units:
			unit.move_to(destination)
		return

	for unit in SelectionManager.selected_units:
		unit.move_to(destination)
