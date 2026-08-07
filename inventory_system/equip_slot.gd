class_name EquipSlot
extends MarginContainer

@onready var item_layer: Control = $ItemLayer
@onready var ghost_preview: ColorRect = $GhostPreview

var equipped_item: Item = null

func _ready() -> void:
	if not mouse_exited.is_connected(_on_mouse_exited):
		mouse_exited.connect(_on_mouse_exited)

func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		ghost_preview.visible = false

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	var can_accept := data is Item and accepts_item(data)
	ghost_preview.visible = can_accept
	return can_accept

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if not (data is Item) or not accepts_item(data):
		return
	data.detach_from_current_location()
	equip(data)
	ghost_preview.visible = false

func _on_mouse_exited() -> void:
	ghost_preview.visible = false

func equip(item: Item) -> void:
	if equipped_item:
		unequip()

	if item.get_parent():
		item.reparent(item_layer)
	else:
		item_layer.add_child(item)
	equipped_item = item

	item.layout = Item.LayoutMode.EQUIPPED
	item.size = item_layer.size
	item.position = Vector2.ZERO

func unequip() -> void:
	equipped_item = null

func accepts_item(item: Item) -> bool:
	# For now, any item is acceptable (besides whatever's already here). You
	# could validate item type here later.
	return equipped_item == null or equipped_item == item
