class_name Inventory
extends Control

@onready var scroll_container: ScrollContainer = $ScrollContainer
@onready var ghost_preview: ColorRect = $ScrollContainer/ItemLayer/GhostPreview
@onready var item_layer: Control = $ScrollContainer/ItemLayer

@export var cell_size_px: int = 64
@export var width: int = 12
@export var height: int = 6

func _ready() -> void:
	item_layer.custom_minimum_size = Vector2i(width * cell_size_px, height * cell_size_px)

func _physics_process(delta: float) -> void:
	var dragged_item := get_dragged_item()
	if not dragged_item:
		return

	var hovered_inventory := get_hovered_inventory()
	if hovered_inventory != self:
		return

	var mouse_pos := scroll_container.get_local_mouse_position()
	var s_size := scroll_container.size

	# Dynamic edge margins based on item size
	var base_margin := 24.0
	var max_margin := 64.0
	var item_px := dragged_item.get_cell_size() * cell_size_px

	var horizontal_margin: float = clamp(item_px.x * 0.5, base_margin, max_margin)
	var vertical_margin: float = clamp(item_px.y * 0.5, base_margin, max_margin)

	var scroll_speed := 640.0

	# Horizontal ramp
	if mouse_pos.x < horizontal_margin:
		var strength: float = 1.0 - (mouse_pos.x / horizontal_margin)
		scroll_container.scroll_horizontal -= int(strength * scroll_speed * delta)
	elif mouse_pos.x > s_size.x - horizontal_margin:
		var strength: float = (mouse_pos.x - (s_size.x - horizontal_margin)) / horizontal_margin
		scroll_container.scroll_horizontal += int(strength * scroll_speed * delta)

	# Vertical ramp
	if mouse_pos.y < vertical_margin:
		var strength: float = 1.0 - (mouse_pos.y / vertical_margin)
		scroll_container.scroll_vertical -= int(strength * scroll_speed * delta)
	elif mouse_pos.y > s_size.y - vertical_margin:
		var strength: float = (mouse_pos.y - (s_size.y - vertical_margin)) / vertical_margin
		scroll_container.scroll_vertical += int(strength * scroll_speed * delta)

func is_dragging_item() -> bool:
	var drag_layer = get_tree().get_nodes_in_group("drag_layer")
	if drag_layer.is_empty():
		return false

	for item in drag_layer[0].get_children():
		if item is Item and item.dragging:
			return true
	return false

func get_dragged_item() -> Item:
	var layers = get_tree().get_nodes_in_group("drag_layer")
	if layers.is_empty():
		return null
	for node in layers[0].get_children():
		if node is Item and node.dragging:
			return node
	return null

func get_hovered_inventory() -> Inventory:
	var items := get_tree().get_nodes_in_group("inventories")
	var mouse_pos := get_global_mouse_position()

	for inv in items:
		var scroll: ScrollContainer = inv.scroll_container
		var rect := Rect2(scroll.get_global_transform().origin, scroll.size)
		if rect.has_point(mouse_pos):
			return inv
	return null

func can_place_item(item: Item, grid_position: Vector2i) -> bool:
	var item_rect = Rect2i(grid_position, item.get_cell_size())
	var inventory_bounds = Rect2i(Vector2i.ZERO, Vector2i(width, height))

	if not inventory_bounds.encloses(item_rect):
		return false

	# Check for item collisions
	for existing_item in item_layer.get_children():
		if existing_item == item:
			continue
		if not existing_item is Item:
			continue

		var local_pos = item_layer.get_global_transform().affine_inverse() * existing_item.global_position
		var other_pos = (local_pos / cell_size_px).floor()
		var other_rect = Rect2i(other_pos, existing_item.get_cell_size())

		if item_rect.intersects(other_rect):
			return false

	# Check for on-screen visibility (at least partial)
	var item_rect_px = Rect2(grid_position * cell_size_px, item.get_cell_size() * cell_size_px)
	var visible_rect = Rect2(
		scroll_container.scroll_horizontal,
		scroll_container.scroll_vertical,
		scroll_container.size.x,
		scroll_container.size.y
	)

	if not item_rect_px.intersects(visible_rect):
		return false

	return true

## considers the whole itemlayer instead of just the visible itemlayer
func can_place_item_logical(item: Item, grid_position: Vector2i) -> bool:
	var item_rect = Rect2i(grid_position, item.get_cell_size())
	var inventory_bounds = Rect2i(Vector2i.ZERO, Vector2i(width, height))

	if not inventory_bounds.encloses(item_rect):
		return false

	for existing_item in item_layer.get_children():
		if existing_item == item:
			continue
		if not existing_item is Item:
			continue

		var local_pos = item_layer.get_global_transform().affine_inverse() * existing_item.global_position
		var other_pos = (local_pos / cell_size_px).floor()
		var other_rect = Rect2i(other_pos, existing_item.get_cell_size())

		if item_rect.intersects(other_rect):
			return false

	return true

func update_ghost_preview(item: Item) -> void:
	var local_pos = item_layer.get_global_transform().affine_inverse() * item.global_position
	var grid_position = (local_pos / cell_size_px).floor()

	grid_position.x = clamp(grid_position.x, 0, width - item.width)
	grid_position.y = clamp(grid_position.y, 0, height - item.height)

	var is_valid = can_place_item(item, grid_position)

	item.ghost_state = {
		"inventory": self,
		"grid_position": grid_position,
		"valid": is_valid
	}

	ghost_preview.size = item.get_cell_size() * cell_size_px
	ghost_preview.position = grid_position * cell_size_px
	ghost_preview.visible = true

	if is_valid:
		ghost_preview.color = Color(1, 1, 1, 0.3)
	else:
		ghost_preview.color = Color(1, 0, 0, 0.5)

func hide_ghost_preview() -> void:
	ghost_preview.visible = false

func request_item_drop(item: Item, grid_position: Vector2i) -> void:
	if item.get_parent() != item_layer and item.get_parent() != null:
		item.get_parent().remove_child(item)

	if not can_place_item(item, grid_position):
		print("Item placement blocked (mismatch with ghost state)")
		return

	item.position = grid_position * cell_size_px
	item_layer.add_child(item)

func find_first_valid_slot(item: Item) -> Vector2i:
	for y in range(height - item.height + 1):
		for x in range(width - item.width + 1):
			var pos = Vector2i(x, y)
			if can_place_item_logical(item, pos):
				return pos
	return Vector2i(-1, -1)

func auto_place_item(item: Item) -> bool:
	var pos = find_first_valid_slot(item)
	if pos != Vector2i(-1, -1):
		if item.get_parent() != null:
			item.get_parent().remove_child(item)
		item_layer.add_child(item)
		item.position = pos * cell_size_px
		return true
	return false

func sort_items() -> void:
	var items := []
	for child in item_layer.get_children():
		if child is Item:
			items.append(child)
			item_layer.remove_child(child)

	items.sort_custom(func(a, b):
		var a_pos = a.position / cell_size_px
		var b_pos = b.position / cell_size_px

		if a_pos.y < b_pos.y:
			return true
		elif a_pos.y > b_pos.y:
			return false
		else:
			if a_pos.x < b_pos.x:
				return true
			else:
				return false
	)

	var occupied := []

	for item in items:
		var pos = find_first_valid_slot(item)
		if pos != Vector2i(-1, -1):
			item.position = pos * cell_size_px
			item_layer.add_child(item)
			occupied.append(Rect2i(pos, item.get_cell_size()))
