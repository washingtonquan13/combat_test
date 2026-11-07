@tool
class_name Inventory
extends Control

const ITEM_SCENE: PackedScene = preload("res://systems/inventory_system/item.tscn")

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

	# Adopt hand-authored Items now, before any of them can be dragged as
	# a widget with no instance behind it.
	if not Engine.is_editor_hint():
		get_container()

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
		item_layer.queue_redraw()
	# Widgets read the cell size from the layer; they only need re-laying.
	for widget in _widgets.values():
		widget._update_size()
		widget._show_sockets()
		widget.position = _container.cell_of(widget.instance) * cell_size_px

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

func can_place_item(item: Item, grid_position: Vector2i) -> bool:
	if not can_place_item_logical(item, grid_position):
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
	return get_container().fits(item.instance, grid_position)

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

## A drop onto this grid: a move when the item is already here, otherwise
## the instance leaves wherever it was (another grid, an equip slot) and
## lands here. The widget follows from the container's signals.
func request_item_drop(item: Item, grid_position: Vector2i) -> void:
	if not can_place_item(item, grid_position):
		return

	var container := get_container()
	if not container.has_instance(item.instance):
		item.detach_from_current_location()
	container.place(item.instance, grid_position)
	hide_ghost_preview()

func find_first_valid_slot(item: Item) -> Vector2i:
	return get_container().first_free_cell(item.instance)

func auto_place_item(item: Item) -> bool:
	var container := get_container()
	if container.first_free_cell(item.instance) == Vector2i(-1, -1):
		return false
	item.detach_from_current_location()
	return container.add(item.instance)

func sort_items() -> void:
	get_container().sort()


## --- The model ---
## This widget draws an ItemContainer; it doesn't own the contents.
## bind() points it at one that lives elsewhere (the party's, owned by
## PartyManager). A stash's Inventory binds nothing and builds its own
## the first time it's asked, adopting any Items authored by hand under
## ItemLayer in the scene (chest.tscn) so editor authoring keeps working.

var _container: ItemContainer
var _widgets: Dictionary = {}  # ItemInstance -> Item
## Items it rejects are drawn dimmed, still there to drag; see set_filter().
var _filter: Callable = func(_i: ItemInstance) -> bool: return true
const FILTERED_OUT := Color(1, 1, 1, 0.25)

## Dims every item filter returns false for, now and as items arrive.
func set_filter(filter: Callable) -> void:
	_filter = filter
	for instance in _widgets:
		_apply_filter(instance)

func _apply_filter(instance: ItemInstance) -> void:
	_widgets[instance].modulate = Color.WHITE if _filter.call(instance) else FILTERED_OUT

func bind(container: ItemContainer) -> void:
	if _container == container:
		return
	if _container:
		_container.item_added.disconnect(_on_item_added)
		_container.item_removed.disconnect(_on_item_removed)
		_container.item_moved.disconnect(_on_item_moved)
	for widget in _widgets.values():
		_free_widget(widget)
	_widgets.clear()

	_container = container
	width = container.width
	height = container.height
	container.item_added.connect(_on_item_added)
	container.item_removed.connect(_on_item_removed)
	container.item_moved.connect(_on_item_moved)
	for instance in container.items():
		_on_item_added(instance)

func get_container() -> ItemContainer:
	if not _container:
		var authored: Array[Item] = []
		for child in _resolve_item_layer().get_children():
			if child is Item and child.instance == null:
				authored.append(child)
		var container := ItemContainer.new(width, height)
		for item in authored:
			var cell: Vector2i = (item.position / cell_size_px).floor()
			_free_widget(item)
			if not item.definition:
				continue
			if not container.place(ItemInstance.new(item.definition, item.current_stack_count), cell):
				push_warning("Inventory: authored '%s' overlaps or leaves the grid at %s" % [item.name, cell])
		bind(container)
	return _container

func _on_item_added(instance: ItemInstance) -> void:
	var item: Item = ITEM_SCENE.instantiate()
	item.instance = instance
	item.container = _container
	item.layout = Item.LayoutMode.GRID
	_resolve_item_layer().add_child(item)
	item.position = _container.cell_of(instance) * cell_size_px
	_widgets[instance] = item
	_apply_filter(instance)

func _on_item_removed(instance: ItemInstance) -> void:
	var item: Item = _widgets.get(instance)
	_widgets.erase(instance)
	if item:
		item.container = null
		_free_widget(item)

func _on_item_moved(instance: ItemInstance) -> void:
	var item: Item = _widgets.get(instance)
	if item:
		item.position = _container.cell_of(instance) * cell_size_px
		# A drag fades the widget and restores it at full alpha.
		_apply_filter(instance)

## Out of the layer at once (so nothing iterating it, or a drop landing
## this frame, sees a stale widget), freed at the end of the frame (it
## may be the drag data of the drop being handled right now).
func _free_widget(item: Item) -> void:
	if item.get_parent():
		item.get_parent().remove_child(item)
	item.queue_free()

func has_item(gear_data: GearItem) -> bool:
	return get_container().has(gear_data)

func consume_item(gear_data: GearItem) -> bool:
	return get_container().consume(gear_data)


## --- Save/load ---
## Part of the save_state()/load_state() contract WorldManager's
## reconciliation pass duck-types against for a stash (see
## stash_component.gd). Delegates to the container; the party's own
## inventory is saved by PartyManager, which owns its container.
##
## May run before this node has entered the tree (WorldManager reconciles
## a stash before adding its world), which is why everything here goes
## through _resolve_item_layer() rather than the @onready member.
func save_state() -> Dictionary:
	return get_container().save_state()

func load_state(state: Dictionary) -> void:
	get_container().load_state(state)


## The live item_layer member when valid, get_node() otherwise. item_layer
## is @onready, unresolved until THIS node's own _ready() has run — untrue
## in WorldManager's detached, pre-add_child() reconciliation window (see
## save_state()'s header). get_node() works regardless, since it walks the
## already-built child structure rather than depending on tree-entry
## timing.
func _resolve_item_layer() -> Node:
	if is_instance_valid(item_layer):
		return item_layer
	return get_node("ScrollContainer/ItemLayer")
