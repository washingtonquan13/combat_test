class_name EquipSlot
extends MarginContainer

@onready var item_layer: Control = $ItemLayer
@onready var ghost_preview: ColorRect = $GhostPreview

## Which kind of GearItem this slot accepts — see accepts_item().
@export var slot_type: GearItem.SlotType = GearItem.SlotType.HELMET

## This specific slot's stable identity, used as UnitEquipment's storage
## key — deliberately a SEPARATE concept from slot_type above, which
## only answers "what kind of item fits here" (any ring fits any ring
## slot, so GearItem.SlotType.RING alone can't tell the two ring slots
## apart; Slot below can, since it has one value per actual slot).
## Authored per-instance in party_overview.tscn, one of these 16 values
## per EquipSlot node — replaces keying storage off this node's own
## scene-tree name, which broke silently on a rename (see
## UnitEquipment's own header for why that mattered).
enum Slot {
	HELMET, AMULET, CLOAK, CHEST_ARMOR, UNDERSHIRT, BRACERS,
	RING_1, RING_2, GLOVES, BELT, LEGS, BOOTS,
	MELEE_MAIN_HAND, MELEE_OFF_HAND, RANGED_MAIN_HAND, RANGED_OFF_HAND,
}
@export var slot: Slot = Slot.HELMET

## Which unit this slot currently represents — assigned by
## party_overview.gd's open_for(), not per-instance in the .tscn (all 16
## slots are shared UI, re-pointed at whichever unit's sheet is open).
## equip()/unequip() only touch the unit's stat modifiers/storage when
## this is set; display_item()/clear_display() below never do, regardless.
@export var unit: Unit

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

## Real equip — a drag-and-drop from the inventory grid (see
## _drop_data). Places the item AND registers its stat modifiers on
## unit (if set). party_overview.gd's unit-switch swap deliberately
## does NOT call this — see display_item() below.
func equip(item: Item) -> void:
	if equipped_item:
		unequip()
	display_item(item)
	if unit:
		unit.equip_item(slot, item)


## Real unequip — counterpart to equip(), same "drag-and-drop only"
## scope. Reverts unit's stat modifiers before clearing the display.
func unequip() -> void:
	if unit and equipped_item:
		unit.unequip_item(slot)
	clear_display()


## Pure visual placement, no stat/storage side effects — reparents item
## into view with no idea whether it's a NEW equip or just redisplaying
## something already equipped on unit. party_overview.gd's open_for()
## uses this (paired with clear_display()) when swapping which unit's
## sheet is shown: the item's already registered on its owning unit,
## nothing needs registering again just because it's visible again.
func display_item(item: Item) -> void:
	if item.get_parent():
		item.reparent(item_layer)
	else:
		item_layer.add_child(item)
	equipped_item = item

	item.layout = Item.LayoutMode.EQUIPPED
	item.size = item_layer.size
	item.position = Vector2.ZERO


## Visual-only counterpart to display_item() — see its header.
func clear_display() -> void:
	equipped_item = null

func accepts_item(item: Item) -> bool:
	if not (equipped_item == null or equipped_item == item):
		return false
	return item.gear_data != null and item.gear_data.slot_type == slot_type
