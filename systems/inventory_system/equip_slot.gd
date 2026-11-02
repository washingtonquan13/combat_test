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

## The widget showing whatever unit has in this slot — a view only,
## built by display_instance() and freed by clear_display(). What's worn
## lives on the unit (UnitEquipment), as an ItemInstance.
var equipped_item: Item = null

const ITEM_SCENE: PackedScene = preload("res://systems/inventory_system/item.tscn")

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
	var instance: ItemInstance = data.instance
	data.detach_from_current_location()
	equip(instance)
	ghost_preview.visible = false

func _on_mouse_exited() -> void:
	ghost_preview.visible = false

## Real equip — a drag-and-drop or the context menu's Equip. Shows the
## instance AND registers it on unit (if set), stat modifiers included.
## party_overview.gd's unit-switch swap deliberately does NOT call this —
## see display_instance() below.
func equip(instance: ItemInstance) -> void:
	if equipped_item:
		unequip()
	display_instance(instance)
	if unit:
		unit.equip_item(slot, instance)


## Real unequip — counterpart to equip(). Reverts unit's stat modifiers
## before clearing the display.
func unequip() -> void:
	if unit and equipped_item:
		unit.unequip_item(slot)
	clear_display()


## Pure visual placement, no stat/storage side effects — builds a widget
## for instance with no idea whether it's a NEW equip or just showing
## something already equipped on unit. party_overview.gd's unit switch
## uses this (paired with clear_display()): the instance is already
## registered on its unit, nothing needs registering again just because
## it's visible again.
func display_instance(instance: ItemInstance) -> void:
	clear_display()
	if not instance:
		return
	var item: Item = ITEM_SCENE.instantiate()
	item.instance = instance
	item.layout = Item.LayoutMode.EQUIPPED
	item_layer.add_child(item)
	item.size = item_layer.size
	item.position = Vector2.ZERO
	equipped_item = item


## Visual-only counterpart to display_instance() — see its header.
## Out of the slot at once, freed at the end of the frame (the widget may
## be the drag data of the drop being handled right now).
func clear_display() -> void:
	if equipped_item:
		if equipped_item.get_parent():
			equipped_item.get_parent().remove_child(equipped_item)
		equipped_item.queue_free()
	equipped_item = null

func accepts_item(item: Item) -> bool:
	if not (equipped_item == null or equipped_item == item):
		return false
	return accepts(item.instance)

func accepts(instance: ItemInstance) -> bool:
	return instance != null and instance.gear_data != null and instance.gear_data.slot_type == slot_type
