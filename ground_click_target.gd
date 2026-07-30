extends StaticBody3D
## Attach to your ground/terrain collision body. Left-click on empty ground
## clears the current selection; right-click issues a move order to the
## selected unit(s) toward the clicked point.
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
		SelectionManager.deselect_all()
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		_command_move(click_position)


func _command_move(destination: Vector3) -> void:
	if CombatManager.in_combat:
		# Only the acting unit may move, and only on its own turn — a
		# right-click while other units are selected (or it's not your
		# turn) is silently ignored rather than moving the wrong unit.
		var unit: Unit = CombatManager.current_unit
		if unit and unit in SelectionManager.selected_units:
			unit.move_to(destination)
		return

	for unit in SelectionManager.selected_units:
		unit.move_to(destination)
