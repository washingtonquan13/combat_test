extends Control
## Loot-transfer UI: two Inventory-hosting slots side by side, one for
## the currently open StashComponent, one for the party's shared
## Inventory (borrowed from PartyOverview). Neither Inventory node is
## copied or rebuilt — both get REPARENTED in on open and back out on
## close, the same idiom Item/EquipSlot already use to move an item
## between containers (see stash_component.gd, party_overview.gd's
## get_inventory()).
##
## Purely reactive to StashManager's signals, same split DialogueOverlay
## already uses with DialogueManager — this file owns "what the screen
## looks like while looting," StashManager owns "is a stash open."
##
## Also owns making the stash's Inventory visible/invisible — it's not
## under any Control/CanvasLayer ancestor while parked on its owner (a
## chest's StaticBody3D, say), but Control rendering only needs a
## Viewport, not a CanvasItem ancestor, so it would otherwise render in
## screen space at all times. See stash_component.gd's header.

@export var party_overview: PartyOverview

@onready var _stash_title: Label = $ContentArea/ChestColumn/VBoxContainer/ChestTitle
@onready var _stash_slot: MarginContainer = $ContentArea/ChestColumn/VBoxContainer/ChestSlot
@onready var _party_slot: MarginContainer = $ContentArea/PartyColumn/VBoxContainer/PartySlot
@onready var _take_all_button: Button = $ContentArea/ChestColumn/VBoxContainer/TakeAllButton

var _stash: StashComponent = null


func _ready() -> void:
	visible = false
	StashManager.stash_opened.connect(_on_stash_opened)
	StashManager.stash_closed.connect(_on_stash_closed)
	$TopBar/CloseButton.pressed.connect(func(): StashManager.close_stash())
	_take_all_button.pressed.connect(_on_take_all_pressed)


func _on_stash_opened(stash: StashComponent, _actor: Unit) -> void:
	_stash = stash
	party_overview.visible = false
	_stash_title.text = stash.display_name
	stash.inventory.reparent(_stash_slot)
	stash.inventory.visible = true
	party_overview.get_inventory().reparent(_party_slot)
	visible = true


func _on_stash_closed() -> void:
	if is_instance_valid(_stash):
		_stash.inventory.visible = false
		_stash.inventory.reparent(_stash)
	party_overview.get_inventory().reparent(party_overview.get_inventory_slot())
	visible = false
	_stash = null


## Bulk-move convenience — same "one button, one Inventory method" shape
## as party_overview.gd's own SortButton/sort_items(). auto_place_item
## already declines anything that doesn't fit, so a full party inventory
## just leaves the rest behind in the stash rather than losing anything.
func _on_take_all_pressed() -> void:
	if not is_instance_valid(_stash):
		return
	var party_inventory: Inventory = party_overview.get_inventory()
	for item in _stash.inventory.item_layer.get_children().duplicate():
		if item is Item:
			party_inventory.auto_place_item(item)
