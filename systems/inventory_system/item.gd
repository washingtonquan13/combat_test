@tool
class_name Item
extends Container

@onready var background: ColorRect = $Background
@onready var icon_rect: TextureRect = $Icon
@onready var stack_count_label: Label = $StackCount
@onready var rarity_frame: ReferenceRect = $RarityFrame
@onready var socket_overlay: SocketOverlay = $Sockets

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
	get: return (instance.definition if instance else definition) as GearItem
@export var icon: Texture2D:
	set(value):
		icon = value
		if is_instance_valid(icon_rect):
			icon_rect.texture = value
## Pixels per cell of the grid this widget sits in, read from that grid
## (Inventory.cell_size_px) so the two can't disagree; 0 out of a grid.
var cell_size_px: int:
	get:
		var layer := get_parent() as InventoryGridLayer
		return layer.cell_size_px if layer else 0
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
## Authoring input only, for Items placed by hand in a scene (chest.tscn):
## Inventory adopts those into its ItemContainer, and from then on the
## count lives on `instance`.
@export var current_stack_count: int = 1
@export var maximum_stack_count: int = 99

## The copy this widget shows. Everything per-copy (the stack count
## today) is read from here; the widget itself holds nothing that has to
## survive it being freed — Inventory and EquipSlot free and rebuild
## widgets freely.
var instance: ItemInstance:
	set(value):
		if instance and instance.changed.is_connected(_on_instance_changed):
			instance.changed.disconnect(_on_instance_changed)
		instance = value
		if instance:
			instance.changed.connect(_on_instance_changed)
			definition = instance.definition
		_on_instance_changed()

## The grid this widget's instance sits in, or null when it's shown in
## an EquipSlot. Set by Inventory.
var container: ItemContainer

enum LayoutMode { GRID, EQUIPPED }
@export var layout: LayoutMode = LayoutMode.GRID:
	set(value):
		layout = value
		_update_size()
		_show_sockets()

var is_being_dragged: bool = false
var context_menu: Window = null

func _ready() -> void:
	if is_instance_valid(icon_rect):
		icon_rect.texture = icon
	_update_size()
	update_stack_count_label()
	_show_sockets()

func _update_size() -> void:
	if layout == LayoutMode.GRID and cell_size_px > 0:
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
		NOTIFICATION_PARENTED:
			_update_size()
			_show_sockets()
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
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	# As big as it's drawn where it was picked up: its footprint in a
	# grid, the slot in an EquipSlot.
	preview.size = size
	preview.position = -preview.size / 2
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_drag_preview(preview)
	return self

func get_parent_equip_slot() -> EquipSlot:
	var parent := get_parent()
	if parent and parent.get_parent() and parent.get_parent() is EquipSlot:
		return parent.get_parent() as EquipSlot
	return null

## Takes this widget's instance out of wherever it lives (a grid or an
## equip slot, including the unit's stat bookkeeping), so it's ready to
## be placed somewhere new. The widget itself is freed by whichever view
## was showing it; the instance is what moves.
func detach_from_current_location() -> void:
	var slot := get_parent_equip_slot()
	if slot:
		slot.unequip()
	elif container:
		container.remove(instance)
		container = null

func _on_instance_changed() -> void:
	if instance:
		current_stack_count = instance.count
	update_stack_count_label()
	_show_sockets()


## Rarity frame, and the sockets over the art — only in the grid, where
## the art is at its true footprint; the shrunken equipped preview leaves
## them to the tooltip's full-size art.
func _show_sockets() -> void:
	if not is_instance_valid(socket_overlay):
		return
	rarity_frame.visible = instance != null and instance.rarity != ItemInstance.Rarity.NORMAL
	if instance:
		rarity_frame.border_color = instance.rarity_color()
	socket_overlay.visible = layout == LayoutMode.GRID
	socket_overlay.show_sockets(instance, cell_size_px)


## Dropping a usable item on this one — a rune into a free socket, an awl
## for a new socket — uses one of it on this copy. Anything else falls
## through to the grid under this widget, as a move.
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return data is Item and data != self and instance != null and data.instance != null 		and data.definition.can_apply_to(instance)


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	data.definition.apply_to(instance)
	data.instance.count -= 1
	if data.instance.count <= 0:
		data.detach_from_current_location()

func update_stack_count_label() -> void:
	if is_instance_valid(stack_count_label):
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
	if instance and tooltip.has_method("show_item"):
		tooltip.ready.connect(tooltip.show_item.bind(instance))
	elif tooltip.has_method("set_text"):
		tooltip.ready.connect(tooltip.set_text.bind(for_text))
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
