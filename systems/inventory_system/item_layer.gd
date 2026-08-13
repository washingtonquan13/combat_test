@tool
class_name InventoryGridLayer
extends Control

@onready var inventory: Inventory = get_parent().get_parent()

@export var grid_texture: Texture2D
@export var cell_size_px: int = 64:
	set(value):
		cell_size_px = value
		queue_redraw()

func _ready() -> void:
	if not resized.is_connected(queue_redraw):
		resized.connect(queue_redraw)
	if not mouse_exited.is_connected(_on_mouse_exited):
		mouse_exited.connect(_on_mouse_exited)

func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END and is_instance_valid(inventory):
		inventory.hide_ghost_preview()

func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if not (data is Item) or not is_instance_valid(inventory):
		return false

	var grid_position := _grid_position_from_local(at_position, data)
	inventory.update_ghost_preview(data, grid_position)
	inventory.autoscroll_toward_mouse(data)
	return inventory.can_place_item(data, grid_position)

func _drop_data(at_position: Vector2, data: Variant) -> void:
	if not (data is Item) or not is_instance_valid(inventory):
		return

	var grid_position := _grid_position_from_local(at_position, data)
	inventory.request_item_drop(data, grid_position)

func _grid_position_from_local(at_position: Vector2, item: Item) -> Vector2i:
	var grid_position: Vector2i = (at_position / cell_size_px).floor()
	grid_position.x = clamp(grid_position.x, 0, inventory.width - item.width)
	grid_position.y = clamp(grid_position.y, 0, inventory.height - item.height)
	return grid_position

func _on_mouse_exited() -> void:
	if is_instance_valid(inventory):
		inventory.hide_ghost_preview()

func _draw() -> void:
	if grid_texture == null or cell_size_px <= 0:
		return

	var cols := int(ceil(size.x / cell_size_px))
	var rows := int(ceil(size.y / cell_size_px))

	for y in rows:
		for x in cols:
			var cell_rect := Rect2(Vector2(x, y) * cell_size_px, Vector2(cell_size_px, cell_size_px))
			draw_texture_rect(grid_texture, cell_rect, false)
