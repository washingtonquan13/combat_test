extends Control
## Loot-transfer UI: two Inventory-hosting slots side by side, one for
## the currently open Chest, one for the party's shared Inventory
## (borrowed from PartyOverview). Neither Inventory node is copied or
## rebuilt — both get REPARENTED in on open and back out on close, the
## same idiom Item/EquipSlot already use to move an item between
## containers (see chest.gd, party_overview.gd's get_inventory()).
##
## Purely reactive to StashManager's signals, same split DialogueOverlay
## already uses with DialogueManager — this file owns "what the screen
## looks like while looting," StashManager owns "is a chest open."

@export var party_overview: PartyOverview

@onready var _chest_title: Label = $ContentArea/ChestColumn/VBoxContainer/ChestTitle
@onready var _chest_slot: MarginContainer = $ContentArea/ChestColumn/VBoxContainer/ChestSlot
@onready var _party_slot: MarginContainer = $ContentArea/PartyColumn/VBoxContainer/PartySlot
@onready var _take_all_button: Button = $ContentArea/ChestColumn/VBoxContainer/TakeAllButton

var _chest: Chest = null


func _ready() -> void:
	visible = false
	StashManager.stash_opened.connect(_on_stash_opened)
	StashManager.stash_closed.connect(_on_stash_closed)
	$TopBar/CloseButton.pressed.connect(func(): StashManager.close_stash())
	_take_all_button.pressed.connect(_on_take_all_pressed)


func _on_stash_opened(chest: Chest, _actor: Unit) -> void:
	_chest = chest
	party_overview.visible = false
	_chest_title.text = chest.display_name
	chest.inventory.reparent(_chest_slot)
	party_overview.get_inventory().reparent(_party_slot)
	visible = true


func _on_stash_closed() -> void:
	if is_instance_valid(_chest):
		_chest.inventory.reparent(_chest)
	party_overview.get_inventory().reparent(party_overview.get_inventory_slot())
	visible = false
	_chest = null


## Bulk-move convenience — same "one button, one Inventory method" shape
## as party_overview.gd's own SortButton/sort_items(). auto_place_item
## already declines anything that doesn't fit, so a full party inventory
## just leaves the rest behind in the chest rather than losing anything.
func _on_take_all_pressed() -> void:
	if not is_instance_valid(_chest):
		return
	var party_inventory: Inventory = party_overview.get_inventory()
	for item in _chest.inventory.item_layer.get_children().duplicate():
		if item is Item:
			party_inventory.auto_place_item(item)
