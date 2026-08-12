extends Control
## Classic RTS/CRPG drag-select box.
##
## Scene setup: put this on a Control set to Full Rect anchors, ideally
## under its own CanvasLayer so it draws above the 3D view. mouse_filter is
## forced to IGNORE in _ready() so this control never blocks clicks on
## units or the ground — it reads input purely through _unhandled_input,
## which runs alongside (not instead of) CollisionObject3D physics picking.
## A plain click (no meaningful drag) is left alone, so single-unit
## selection and ground_click_target.gd's deselect-on-empty-click keep
## working exactly as before.
##
## While dragging, units under the box just get a hover-style PREVIEW
## highlight (Unit.set_box_hover) — nothing is actually selected yet.
## The real selection only happens once, on mouse-up, via SelectionManager.
##
## Non-player-controlled units are skipped entirely — see
## Unit.is_player_controlled. SelectionManager would refuse them anyway,
## but filtering here too means they don't even preview-highlight as if
## they were a valid drag-select target.

## Minimum drag distance (px) before this counts as a box-select rather
## than a plain click.
@export var drag_threshold: float = 6.0
@export var box_color: Color = Color(0.3, 0.7, 1.0, 0.15)
@export var border_color: Color = Color(0.3, 0.7, 1.0, 0.8)

var _dragging: bool = false
var _drag_start: Vector2 = Vector2.ZERO
var _drag_end: Vector2 = Vector2.ZERO

## Units currently under the box, live-updated every drag frame — only
## drives the box_hover preview until release, at which point this list
## is exactly what gets committed to SelectionManager.
var _boxed_units: Array[Unit] = []
var _additive: bool = false


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _unhandled_input(event: InputEvent) -> void:
	# Same reasoning as ground_click_target.gd's own guard — no box-
	# selecting units while a live conversation owns the screen.
	if DialogueManager.is_active():
		return

	if event.is_action_pressed("left_click"):
		_drag_start = event.position
		_drag_end = event.position
		_dragging = false
		_additive = Input.is_action_pressed("select_additive")
		_boxed_units.clear()

	elif event.is_action_released("left_click"):
		if _dragging:
			_finish_drag()
		_dragging = false
		queue_redraw()

	elif event is InputEventMouseMotion and Input.is_action_pressed("left_click"):
		_drag_end = event.position
		if not _dragging and _drag_start.distance_to(_drag_end) >= drag_threshold:
			_dragging = true
		if _dragging:
			_update_box_hover_preview()
			queue_redraw()


func _draw() -> void:
	if not _dragging:
		return
	var rect := Rect2(_drag_start, Vector2.ZERO).expand(_drag_end)
	draw_rect(rect, box_color, true)
	draw_rect(rect, border_color, false, 2.0)


## Recomputes which units the box currently overlaps and toggles their
## preview highlight accordingly. Purely visual — never touches
## SelectionManager or is_selected.
func _update_box_hover_preview() -> void:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if not camera:
		return

	var rect := Rect2(_drag_start, Vector2.ZERO).expand(_drag_end)
	var current: Array[Unit] = []

	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if not unit:
			continue
		if not unit.is_player_controlled():
			continue
		if camera.is_position_behind(unit.global_position):
			continue
		var screen_pos: Vector2 = camera.unproject_position(unit.global_position)
		if rect.has_point(screen_pos):
			current.append(unit)

	for unit in current:
		if unit not in _boxed_units:
			unit.set_box_hover(true)

	for unit in _boxed_units:
		if unit not in current:
			unit.set_box_hover(false)

	_boxed_units = current


## Commits whatever the box was last covering as the actual selection, and
## clears the preview flag now that is_selected takes over the highlight.
func _finish_drag() -> void:
	for unit in _boxed_units:
		unit.set_box_hover(false)

	if _boxed_units.is_empty():
		if not _additive:
			SelectionManager.deselect_all()
		_boxed_units.clear()
		return

	for i in _boxed_units.size():
		# First hit replaces the current selection (unless shift is held);
		# every hit after that is always additive so the whole box lands
		# together as one selection.
		SelectionManager.select(_boxed_units[i], _additive or i > 0)

	_boxed_units.clear()
