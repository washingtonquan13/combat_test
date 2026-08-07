class_name EquipSlot
extends MarginContainer

@onready var item_layer: Control = $ItemLayer
@onready var ghost_preview: ColorRect = $GhostPreview

var equipped_item: Item = null

func equip(item: Item) -> void:
	if equipped_item:
		unequip()
	
	if item.get_parent():
		item.reparent(item_layer)
	else:
		item_layer.add_child(item)
	equipped_item = item
	
	item.layout = Item.LayoutMode.EQUIPPED
	item.position = Vector2.ZERO

func unequip() -> void:
	equipped_item = null

func accepts_item(_item: Item) -> bool:
	# For now, all items are acceptable. You could validate type here later.
	return equipped_item == null
