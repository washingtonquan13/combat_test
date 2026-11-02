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
@export var unit: Unit:
	set(value):
		if unit and unit.equipment_changed.is_connected(_on_equipment_changed):
			unit.equipment_changed.disconnect(_on_equipment_changed)
		unit = value
		if unit:
			unit.equipment_changed.connect(_on_equipment_changed)
		_refresh_ghost()

## The widget showing whatever unit has in this slot — a view only,
## built by display_instance() and freed by clear_display(). What's worn
## lives on the unit (UnitEquipment), as an ItemInstance.
var equipped_item: Item = null

## An off-hand slot's faded copy of the two-handed weapon in its main
## hand: shows why the slot is taken. Not an Item, so it can't be
## dragged, right-clicked or counted by accepts_item().
var _ghost: TextureRect = null
## Grey and half-faded: the icon over a grey wash reads as "taken by the
## main hand", not as an item in this slot.
const GHOST_TINT := Color(0.8, 0.8, 0.8, 0.55)

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
	# Anchored, not sized once: on the screen's first open item_layer hasn't
	# been laid out yet (0x0), and a copied size would stay 0x0.
	item.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	equipped_item = item
	_refresh_ghost()


## Visual-only counterpart to display_instance() — see its header.
## Out of the slot at once, freed at the end of the frame (the widget may
## be the drag data of the drop being handled right now).
func clear_display() -> void:
	if equipped_item:
		if equipped_item.get_parent():
			equipped_item.get_parent().remove_child(equipped_item)
		equipped_item.queue_free()
	equipped_item = null
	_refresh_ghost()


func _on_equipment_changed(_unit: Unit) -> void:
	_refresh_ghost()


func _refresh_ghost() -> void:
	var weapon: ItemInstance = null
	if unit and not equipped_item and is_node_ready():
		var main = UnitEquipment.OFF_HAND_OF.find_key(slot)
		if main != null:
			var held: ItemInstance = unit.get_equipped_item(main)
			if UnitEquipment.is_two_handed(held):
				weapon = held
	if not weapon:
		if _ghost:
			_ghost.queue_free()
			_ghost = null
		return
	if not _ghost:
		_ghost = TextureRect.new()
		_ghost.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_ghost.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ghost.modulate = GHOST_TINT
		var wash := ColorRect.new()
		wash.color = Color(0.6, 0.6, 0.6, 0.5)
		wash.show_behind_parent = true
		wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ghost.add_child(wash)
		wash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		item_layer.add_child(_ghost)
		_ghost.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ghost.texture = weapon.definition.icon

func accepts_item(item: Item) -> bool:
	if not (equipped_item == null or equipped_item == item):
		return false
	return accepts(item.instance)

## Identified, fits this slot's type (GearItem.fits: a one-handed weapon
## fits the off hand too) and, on a unit, its other hand allows it. An
## unidentified item can't be worn until a scroll identifies it.
func accepts(instance: ItemInstance) -> bool:
	if instance == null or not instance.identified or instance.gear_data == null \
			or not instance.gear_data.fits(slot_type):
		return false
	return unit == null or unit.hands_allow(slot, instance)
