@tool
class_name Inventory
extends Control

@onready var scroll_container: ScrollContainer = $ScrollContainer
@onready var ghost_preview: ColorRect = $ScrollContainer/ItemLayer/GhostPreview
@onready var item_layer: InventoryGridLayer = $ScrollContainer/ItemLayer
@onready var v_scrollbar: VScrollBar = $VScrollBar
@onready var h_scrollbar: HScrollBar = $HScrollBar

@export var cell_size_px: int = 64:
	set(value):
		cell_size_px = value
		_update_sizes()
## Total grid size — the full logical extent items can be placed in.
@export var width: int = 12:
	set(value):
		width = value
		_update_sizes()
@export var height: int = 6:
	set(value):
		height = value
		_update_sizes()
## Viewport size — how much of the grid is visible without scrolling.
## Set smaller than width/height (e.g. for a chest or shared party stash)
## to make the ScrollContainer actually scroll.
@export var visible_width: int = 12:
	set(value):
		visible_width = value
		_update_sizes()
@export var visible_height: int = 6:
	set(value):
		visible_height = value
		_update_sizes()
## Width reserved for each scrollbar, drawn outside the scrollable viewport
## rather than overlapping it. Only reserved on axes that actually scroll.
@export var scrollbar_thickness: int = 14:
	set(value):
		scrollbar_thickness = value
		_update_sizes()

func _ready() -> void:
	scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER

	if not v_scrollbar.value_changed.is_connected(_on_v_scrollbar_changed):
		v_scrollbar.value_changed.connect(_on_v_scrollbar_changed)
	if not h_scrollbar.value_changed.is_connected(_on_h_scrollbar_changed):
		h_scrollbar.value_changed.connect(_on_h_scrollbar_changed)

	# ScrollContainer's own (now-hidden) scrollbars stay the source of truth
	# for wheel-scroll and edge-autoscroll during drags — mirror their motion
	# onto our external, non-obstructing ones instead of duplicating that logic.
	var internal_v := scroll_container.get_v_scroll_bar()
	if not internal_v.value_changed.is_connected(_on_internal_v_scroll_changed):
		internal_v.value_changed.connect(_on_internal_v_scroll_changed)

	var internal_h := scroll_container.get_h_scroll_bar()
	if not internal_h.value_changed.is_connected(_on_internal_h_scroll_changed):
		internal_h.value_changed.connect(_on_internal_h_scroll_changed)

	_update_sizes()

func _on_v_scrollbar_changed(value: float) -> void:
	scroll_container.scroll_vertical = int(value)

func _on_h_scrollbar_changed(value: float) -> void:
	scroll_container.scroll_horizontal = int(value)

func _on_internal_v_scroll_changed(value: float) -> void:
	v_scrollbar.value = value

func _on_internal_h_scroll_changed(value: float) -> void:
	h_scrollbar.value = value

func _update_sizes() -> void:
	var viewport_size := Vector2i(visible_width, visible_height) * cell_size_px
	var content_size := Vector2i(width, height) * cell_size_px

	var needs_vscroll := height > visible_height
	var needs_hscroll := width > visible_width

	var margin := Vector2i(
		scrollbar_thickness if needs_vscroll else 0,
		scrollbar_thickness if needs_hscroll else 0
	)
	var outer_size := viewport_size + margin

	# custom_minimum_size must shrink first — Control clamps `size` to never go
	# below the *current* custom_minimum_size, so setting size before lowering
	# the floor silently clamps the shrink away.
	custom_minimum_size = outer_size
	size = outer_size

	if is_instance_valid(scroll_container):
		scroll_container.position = Vector2.ZERO
		scroll_container.size = viewport_size

	if is_instance_valid(item_layer):
		item_layer.custom_minimum_size = content_size
		item_layer.cell_size_px = cell_size_px

	if is_instance_valid(v_scrollbar):
		v_scrollbar.visible = needs_vscroll
		v_scrollbar.position = Vector2(viewport_size.x, 0)
		v_scrollbar.size = Vector2(scrollbar_thickness, viewport_size.y)
		v_scrollbar.max_value = content_size.y
		v_scrollbar.page = viewport_size.y

	if is_instance_valid(h_scrollbar):
		h_scrollbar.visible = needs_hscroll
		h_scrollbar.position = Vector2(0, viewport_size.y)
		h_scrollbar.size = Vector2(viewport_size.x, scrollbar_thickness)
		h_scrollbar.max_value = content_size.x
		h_scrollbar.page = viewport_size.x

## Called by ItemLayer's _can_drop_data while a drag hovers over this inventory.
func autoscroll_toward_mouse(item: Item) -> void:
	var mouse_pos := scroll_container.get_local_mouse_position()
	var s_size := scroll_container.size

	# Dynamic edge margins based on item size
	var base_margin := 24.0
	var max_margin := 64.0
	var item_px := item.get_cell_size() * cell_size_px

	var horizontal_margin: float = clamp(item_px.x * 0.5, base_margin, max_margin)
	var vertical_margin: float = clamp(item_px.y * 0.5, base_margin, max_margin)

	var scroll_speed := 640.0
	var delta := get_process_delta_time()

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

func _fits_without_collision(item: Item, grid_position: Vector2i) -> bool:
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

func can_place_item(item: Item, grid_position: Vector2i) -> bool:
	if not _fits_without_collision(item, grid_position):
		return false

	# Check for on-screen visibility (at least partial)
	var item_rect_px = Rect2(grid_position * cell_size_px, item.get_cell_size() * cell_size_px)
	var visible_rect = Rect2(
		scroll_container.scroll_horizontal,
		scroll_container.scroll_vertical,
		scroll_container.size.x,
		scroll_container.size.y
	)

	return item_rect_px.intersects(visible_rect)

## considers the whole itemlayer instead of just the visible itemlayer
func can_place_item_logical(item: Item, grid_position: Vector2i) -> bool:
	return _fits_without_collision(item, grid_position)

func update_ghost_preview(item: Item, grid_position: Vector2i) -> void:
	var is_valid := can_place_item(item, grid_position)

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
	if not can_place_item(item, grid_position):
		return

	item.detach_from_current_location()
	item.layout = Item.LayoutMode.GRID
	item.position = grid_position * cell_size_px
	item_layer.add_child(item)
	hide_ghost_preview()

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
		item.detach_from_current_location()
		item.layout = Item.LayoutMode.GRID
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

		if a_pos.y != b_pos.y:
			return a_pos.y < b_pos.y
		return a_pos.x < b_pos.x
	)

	for item in items:
		var pos = find_first_valid_slot(item)
		if pos != Vector2i(-1, -1):
			item.position = pos * cell_size_px
			item_layer.add_child(item)

func has_item(gear_data: GearItem) -> bool:
	return _find_item(gear_data) != null

## Decrements the matching item's stack, or removes it entirely once its
## stack hits zero. False (no-op) if nothing matched — see
## SacrificeItemEffect, the caller that needs to tell the two apart.
func consume_item(gear_data: GearItem) -> bool:
	var item: Item = _find_item(gear_data)
	if not item:
		return false
	if item.current_stack_count > 1:
		item.current_stack_count -= 1
		item.update_stack_count_label()
	else:
		item.detach_from_current_location()
		item.queue_free()
	return true

func _find_item(gear_data: GearItem) -> Item:
	for child in item_layer.get_children():
		if child is Item and child.gear_data == gear_data:
			return child
	return null
