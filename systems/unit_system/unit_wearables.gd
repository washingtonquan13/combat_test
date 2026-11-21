class_name UnitWearables
extends Node
## Dresses the body in what the unit wears - the worn counterpart of
## UnitWeapons, wired the same way and deciding nothing. Every equipped
## item with a GearItem.wearable goes on the body through its
## CharacterLook or, on a Character Creator body, its CCLook (each has
## wear()). A body with neither - a demon, a placeholder mannequin - wears
## nothing.

@export var unit: Unit

## What the last refresh put on, to skip rebuilding when nothing worn
## changed (loadout_changed also fires for abilities).
var _shown: Array = []


func _ready() -> void:
	if not unit:
		unit = get_parent() as Unit
	unit.loadout_changed.connect(func(_unit: Unit) -> void: refresh())
	# Deferred: equipment restored from a save or authored on the unit
	# lands after the unit's own _ready, without a signal.
	refresh.call_deferred()


## Puts on the body whatever the Unit has equipped.
func refresh() -> void:
	if not is_instance_valid(unit):
		return
	var body := unit.get_node_or_null("CharacterModel") as CharacterModel
	var look: Node = null
	if body:
		for child in body.get_children():
			if child is CharacterLook:
				look = child
	var items: Array[Wearable] = []
	for slot: EquipSlot.Slot in EquipSlot.Slot.values():
		var item: ItemInstance = unit.get_equipped_item(slot)
		var gear := item.definition as GearItem if item else null
		if gear and gear.wearable:
			items.append(gear.wearable)
	var shown: Array = [look, items]
	if look == null or shown == _shown:
		return
	_shown = shown
	look.wear(items)
