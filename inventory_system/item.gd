@tool
class_name Item
extends Container

@onready var background: ColorRect = $Background
@onready var icon_rect: TextureRect = $Icon
@onready var stack_count_label: Label = $StackCount

@export var tooltip_scene: PackedScene
@export var context_menu_scene: PackedScene
@export var icon: Texture2D
@export var cell_size_px: int = 64
@export var width: int = 1
@export var height: int = 1
@export var current_stack_count: int = 1
@export var maximum_stack_count: int = 99

enum LayoutMode { GRID, EQUIPPED }
@export var layout: LayoutMode = LayoutMode.GRID

var dragging: bool = false
var drag_offset: Vector2 = Vector2.ZERO
var inventories: Array = []
var previous_equip_slot: EquipSlot = null
var previous_inventory: Inventory = null
var last_position: Vector2 = Vector2.ZERO
var original_parent: Node = null
var active_tooltip: Control = null
var context_menu: Control = null

var hover_time: float = 0.0
const TOOLTIP_DELAY := 0.3

var ghost_state := {
	"inventory": null,
	"grid_position": Vector2i(-1, -1),
	"valid": false
}

func _ready() -> void:
	set_process_unhandled_input(true)

func _process(_delta: float) -> void:
	# Ensure node is fully initialized
	if not is_instance_valid(icon_rect):
		return

	# Optional: only update if icon changed or needs refreshing
	if icon_rect.texture != icon:
		icon_rect.texture = icon

	if layout == LayoutMode.GRID:
		size = Vector2i(width, height) * cell_size_px
	elif layout == LayoutMode.EQUIPPED:
		size = Vector2i(80, 80)

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return

	var mouse_inside := is_mouse_visible_and_hovered()

	# Tooltip logic
	if mouse_inside and not dragging:
		hover_time += delta
		if hover_time >= TOOLTIP_DELAY:
			show_tooltip()
	else:
		hover_time = 0.0
		hide_tooltip()

	# Background alpha
	if mouse_inside:
		background.color.a = 0.8
	else:
		background.color.a = 0.5

	if dragging:
		var drag_layer := get_drag_layer()
		if drag_layer:
			global_position = get_global_mouse_position() - drag_offset

		# Inventory ghost logic
		var new_inventory := get_hovered_inventory()
		if previous_inventory != new_inventory:
			if previous_inventory:
				previous_inventory.hide_ghost_preview()
			previous_inventory = new_inventory

		if previous_inventory:
			previous_inventory.update_ghost_preview(self)

		# Equip slot ghost logic
		var hovered_slot := get_hovered_equip_slot()
		for slot in get_tree().get_nodes_in_group("equip_slots"):
			if slot == hovered_slot:
				slot.ghost_preview.visible = true
			else:
				slot.ghost_preview.visible = false

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			dragging = true
			hide_tooltip()
			background.visible = false
			last_position = global_position
			inventories = get_all_inventories()
			original_parent = get_parent()

			# Handle drag origin from equip slot
			var slot := get_parent_equip_slot()
			if slot:
				previous_equip_slot = slot
				slot.unequip()
				layout = LayoutMode.GRID
				size = Vector2i(width, height) * cell_size_px  # Force size update
				drag_offset = size / 2  # Recenter drag

			var drag_layer = get_drag_layer()
			if drag_layer:
				if original_parent:
					original_parent.remove_child(self)
				drag_layer.add_child(self)
				# Redundant recentering in case drag_offset was set before drag_layer move
				drag_offset = size / 2

	elif event is InputEventMouseMotion and dragging:
		var screen_rect: Rect2 = get_viewport_rect()
		var proposed_position: Vector2 = get_global_mouse_position() - drag_offset
		proposed_position.x = clamp(proposed_position.x, 0, screen_rect.size.x - size.x)
		proposed_position.y = clamp(proposed_position.y, 0, screen_rect.size.y - size.y)
		global_position = proposed_position

		var hovered_inventory: Inventory = get_hovered_inventory()
		if hovered_inventory:
			hovered_inventory.update_ghost_preview(self)
	
	#if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		#open_context_menu()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT and dragging:
		end_drag()

func update_drag_offset() -> void:
	drag_offset = size / 2

func get_parent_equip_slot() -> EquipSlot:
	var parent := get_parent()
	if parent and parent.get_parent() and parent.get_parent() is EquipSlot:
		return parent.get_parent() as EquipSlot
	return null

func end_drag() -> void:
	dragging = false
	background.visible = true

	var hovered_slot := get_hovered_equip_slot()
	if hovered_slot and hovered_slot.accepts_item(self):
		hovered_slot.equip(self)
	else:
		if ghost_state["valid"] and ghost_state["inventory"]:
			ghost_state["inventory"].request_item_drop(self, ghost_state["grid_position"])
			ghost_state["inventory"].hide_ghost_preview()
		elif previous_equip_slot:
			previous_equip_slot.equip(self)
		else:
			if get_parent() != original_parent and original_parent:
				get_parent().remove_child(self)
				original_parent.add_child(self)
			global_position = last_position

	for inventory in inventories:
		inventory.hide_ghost_preview()

	for slot_node in get_tree().get_nodes_in_group("equip_slots"):
		slot_node.ghost_preview.visible = false

	ghost_state = {
		"inventory": null,
		"grid_position": Vector2i(-1, -1),
		"valid": false
	}

func intersects_inventory(inventory: Inventory) -> bool:
	var item_layer_rect: Rect2 = Rect2(
		inventory.item_layer.get_global_transform().origin,
		Vector2(inventory.width, inventory.height) * inventory.cell_size_px
	)

	return item_layer_rect.has_point(global_position)

func update_stack_count_label() -> void:
	stack_count_label.text = str(current_stack_count)
	stack_count_label.visible = current_stack_count > 1

func get_cell_size() -> Vector2i:
	return Vector2i(width, height)

func get_drag_layer() -> Node:
	var layers: Array = get_tree().get_nodes_in_group("drag_layer")
	if layers.is_empty():
		return null
	return layers[0]

func get_all_inventories() -> Array:
	return get_tree().get_nodes_in_group("inventories")

func get_hovered_inventory() -> Inventory:
	var mouse_pos: Vector2 = get_global_mouse_position()

	for inventory in inventories:
		var scroll: ScrollContainer = inventory.scroll_container
		var item_layer_origin: Vector2 = inventory.item_layer.get_global_transform().origin
		var item_layer_size: Vector2 = Vector2(inventory.width, inventory.height) * inventory.cell_size_px
		var item_layer_rect: Rect2 = Rect2(item_layer_origin, item_layer_size)

		var visible_rect: Rect2 = Rect2(
			scroll.get_global_transform().origin,
			scroll.size
		)

		var visible_region: Rect2 = item_layer_rect.intersection(visible_rect)
		if visible_region and visible_region.has_point(mouse_pos):
			return inventory

	return null

func is_mouse_visible_and_hovered() -> bool:
	var mouse_pos: Vector2 = get_global_mouse_position()
	var item_rect: Rect2 = get_global_rect()

	var scroll: ScrollContainer = find_parent("ScrollContainer")
	if scroll:
		var clip_rect: Rect2 = Rect2(
			scroll.get_global_transform().origin,
			scroll.size
		)
		if not clip_rect.has_point(mouse_pos):
			return false

	return item_rect.has_point(mouse_pos)

func show_tooltip() -> void:
	if active_tooltip != null or tooltip_scene == null or not is_visible_in_tree():
		return

	var layers: Array = get_tree().get_nodes_in_group("tooltip_layer")
	if layers.is_empty():
		return

	var tooltip: Control = tooltip_scene.instantiate()
	tooltip.z_index = 1000
	active_tooltip = tooltip

	if tooltip.has_method("set_text"):
		var text: String = "Item (%d×%d)  Stack: %d" % [width, height, current_stack_count]
		tooltip.set_text(text)

	var tooltip_size: Vector2 = tooltip.get_combined_minimum_size()
	var item_rect: Rect2 = get_global_rect()
	var margin: float = 4.0

	var proposed_pos: Vector2 = item_rect.position + Vector2(item_rect.size.x + margin, 0)
	var proposed_rect: Rect2 = Rect2(proposed_pos, tooltip_size)

	if proposed_rect.intersects(item_rect):
		proposed_pos = item_rect.position - Vector2(tooltip_size.x + margin, 0)

	var screen_rect: Rect2 = get_viewport().get_visible_rect()
	var clamped_x: float = clamp(proposed_pos.x, screen_rect.position.x, screen_rect.end.x - tooltip_size.x)
	var clamped_y: float = clamp(proposed_pos.y, screen_rect.position.y, screen_rect.end.y - tooltip_size.y)
	var final_pos: Vector2 = Vector2(clamped_x, clamped_y)

	var layer: Node = layers[0]
	layer.add_child(tooltip)
	tooltip.global_position = final_pos

func hide_tooltip() -> void:
	if active_tooltip:
		active_tooltip.queue_free()
		active_tooltip = null

func open_context_menu() -> void:
	if context_menu and is_instance_valid(context_menu):
		context_menu.queue_free()

	if context_menu_scene == null:
		return

	var layers := get_tree().get_nodes_in_group("tooltip_layer")
	if layers.is_empty():
		return

	context_menu = context_menu_scene.instantiate()
	context_menu.z_index = 2000
	context_menu.global_position = get_global_mouse_position()
	layers[0].add_child(context_menu)

func get_hovered_equip_slot() -> EquipSlot:
	for slot in get_tree().get_nodes_in_group("equip_slots"):
		var slot_rect: Rect2 = slot.get_global_rect()
		if slot_rect.has_point(get_global_mouse_position()):
			return slot
	return null
