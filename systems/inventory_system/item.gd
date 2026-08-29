@tool
class_name Item
extends Container

@onready var background: ColorRect = $Background
@onready var icon_rect: TextureRect = $Icon
@onready var stack_count_label: Label = $StackCount

@export var tooltip_scene: PackedScene
@export var context_menu_scene: PackedScene
## Definition data for this item — see item_definition.gd/gear_item.gd.
## Setting this cascades into icon/width/height below (their own
## setters still fire _update_size()/_update_tooltip_text() as normal),
## so a new Item pointed at a given definition can't get the wrong
## footprint by hand-authoring mistake. Those three stay directly
## editable too — this isn't a hard lock, just the source of truth when
## it's set. Any Item can have one — gear and non-gear (currency, a
## plain consumable) items alike; only gear ones point at a GearItem
## specifically (see gear_data below).
@export var definition: ItemDefinition:
	set(value):
		definition = value
		if definition:
			icon = definition.icon
			width = definition.width
			height = definition.height
## Read-only view of `definition` typed as GearItem — non-null only when
## this item's definition IS one, e.g. `if item.gear_data:` to check
## "is this item equippable" the same way every existing call site
## already did before `definition` existed. Every read site (EquipSlot,
## UnitEquipment, Inventory's has_item/consume_item, etc.) keeps working
## unchanged; only the few WRITE sites (assigning gear_data =) needed to
## move to `definition` directly.
var gear_data: GearItem:
	get: return definition as GearItem
@export var icon: Texture2D:
	set(value):
		icon = value
		if is_instance_valid(icon_rect):
			icon_rect.texture = value
@export var cell_size_px: int = 64:
	set(value):
		cell_size_px = value
		_update_size()
@export var width: int = 1:
	set(value):
		width = value
		_update_size()
		_update_tooltip_text()
@export var height: int = 1:
	set(value):
		height = value
		_update_size()
		_update_tooltip_text()
@export var current_stack_count: int = 1
@export var maximum_stack_count: int = 99

enum LayoutMode { GRID, EQUIPPED }
@export var layout: LayoutMode = LayoutMode.GRID:
	set(value):
		layout = value
		_update_size()

var is_being_dragged: bool = false
var context_menu: Window = null

func _ready() -> void:
	if is_instance_valid(icon_rect):
		icon_rect.texture = icon
	_update_size()
	_update_tooltip_text()

func _update_size() -> void:
	if layout == LayoutMode.GRID:
		size = Vector2i(width, height) * cell_size_px
	# EQUIPPED layout size is owned by whichever EquipSlot the item is placed in.

func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return

	var mouse_inside := is_mouse_visible_and_hovered()

	# Background alpha
	if mouse_inside:
		background.color.a = 0.8
	else:
		background.color.a = 0.5

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_DRAG_BEGIN:
			if is_same(get_viewport().gui_get_drag_data(), self):
				is_being_dragged = true
				modulate.a = 0.4
		NOTIFICATION_DRAG_END:
			is_being_dragged = false
			modulate.a = 1.0

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		open_context_menu()

func _get_drag_data(_at_position: Vector2) -> Variant:
	var preview := TextureRect.new()
	preview.texture = icon
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.size = Vector2i(width, height) * cell_size_px
	preview.position = -preview.size / 2
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_drag_preview(preview)
	return self

func get_parent_equip_slot() -> EquipSlot:
	var parent := get_parent()
	if parent and parent.get_parent() and parent.get_parent() is EquipSlot:
		return parent.get_parent() as EquipSlot
	return null

## Leaves wherever the item currently lives (grid or equip slot), including
## the equip-slot-side bookkeeping, so it's ready to be added somewhere new.
func detach_from_current_location() -> void:
	var slot := get_parent_equip_slot()
	if slot:
		slot.unequip()

	var parent := get_parent()
	if parent:
		parent.remove_child(self)

func update_stack_count_label() -> void:
	stack_count_label.text = str(current_stack_count)
	stack_count_label.visible = current_stack_count > 1
	_update_tooltip_text()

func _update_tooltip_text() -> void:
	tooltip_text = "Item (%d×%d)  Stack: %d" % [width, height, current_stack_count]

func get_cell_size() -> Vector2i:
	return Vector2i(width, height)

func is_mouse_visible_and_hovered() -> bool:
	var mouse_pos: Vector2 = get_global_mouse_position()
	var item_rect: Rect2 = get_global_rect()

	var scroll := get_ancestor_scroll_container()
	if scroll:
		var clip_rect: Rect2 = Rect2(
			scroll.get_global_transform().origin,
			scroll.size
		)
		if not clip_rect.has_point(mouse_pos):
			return false

	return item_rect.has_point(mouse_pos)

func get_ancestor_scroll_container() -> ScrollContainer:
	var p := get_parent()
	while p:
		if p is ScrollContainer:
			return p
		p = p.get_parent()
	return null

## Godot calls this natively when the built-in hover-tooltip timer elapses;
## returning a Control here shows it instead of the plain default text box.
## Positioning, screen-edge clamping, and show/hide lifecycle are all handled
## by the engine — no manual tooltip_layer node required.
func _make_custom_tooltip(for_text: String) -> Object:
	if tooltip_scene == null:
		return null

	var tooltip: Control = tooltip_scene.instantiate()
	if tooltip.has_method("set_text"):
		tooltip.set_text(for_text)
	return tooltip

## Right-click menu, shown via a Window-based Popup — rendered as a top-most
## overlay by the engine (embedded in the main viewport per project settings),
## with built-in click-outside/Escape-to-close. No manual layer node needed,
## same reasoning as the drag preview and tooltip.
func open_context_menu() -> void:
	if context_menu and is_instance_valid(context_menu):
		context_menu.queue_free()
		context_menu = null

	if context_menu_scene == null:
		return

	var menu: Window = context_menu_scene.instantiate()
	context_menu = menu
	get_tree().root.add_child(menu)

	if menu.has_method("setup"):
		menu.setup(self)

	menu.reset_size()

	var viewport_rect: Rect2 = get_viewport_rect()
	var pos: Vector2 = get_global_mouse_position()
	pos.x = clamp(pos.x, 0, viewport_rect.size.x - menu.size.x)
	pos.y = clamp(pos.y, 0, viewport_rect.size.y - menu.size.y)
	menu.popup(Rect2i(pos, menu.size))
