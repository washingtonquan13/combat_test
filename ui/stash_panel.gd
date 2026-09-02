extends UIScreen
## Loot-transfer UI: two Inventory-hosting slots side by side, one for
## the currently open StashComponent, one for the party's shared
## Inventory (borrowed from PartyOverview). Neither Inventory node is
## copied or rebuilt — both get REPARENTED in on open and back out on
## close, the same idiom Item/EquipSlot already use to move an item
## between containers (see stash_component.gd, party_overview.gd's
## get_inventory()). This reparenting is a separate concern from
## show/hide (owned by UIScreen/UIStack below) and stays exactly as-is.
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
##
## hides_hud/closes_on_cancel stay at UIScreen's own defaults (false and
## true — looting doesn't hide the gameplay HUD today, matching prior
## behavior, and Escape/CloseButton both back out of it).
## blocks_input_below=true is authored on this scene's instance in
## MainRoot.tscn — the party's shared Inventory is a single physical
## node borrowed via reparenting (see above), so it genuinely can't be
## shown by two screens at once; this is what makes party_overview.gd's
## own C-key open correctly refuse to open while looting (see
## UIStack.can_open()), replacing the old hand-rolled
## StashManager.is_active() check there.

@export var party_overview: PartyOverview

@onready var _stash_title: Label = %ChestTitle
@onready var _stash_slot: MarginContainer = %ChestSlot
@onready var _party_slot: MarginContainer = %PartySlot
@onready var _take_all_button: Button = %TakeAllButton

var _stash: StashComponent = null


func _ready() -> void:
	visible = false
	StashManager.stash_opened.connect(_on_stash_opened)
	StashManager.stash_closed.connect(_on_stash_closed)
	%CloseButton.pressed.connect(func(): StashManager.close_stash())
	_take_all_button.pressed.connect(_on_take_all_pressed)
	# See _on_visibility_changed() — this is what keeps StashManager's own
	# "is a stash open" state honest no matter HOW this screen got closed,
	# not just via the Close button above.
	visibility_changed.connect(_on_visibility_changed)


## This screen can be closed by paths that never go through
## StashManager at all — Escape (UIStack._pop_topmost_cancelable, since
## closes_on_cancel defaults true here) and UIStack.close_all(). Both
## only set visible = false, so without this StashManager kept
## current_stash set and GameMode kept LOOTING pushed FOREVER, which
## soft-locked the game outright: can_transition() stayed false, so
## saving and world travel were refused, and CameraDirector.has_control()
## stayed false, so the camera, unit selection and click-to-move all went
## dead with no way back. Routing every close back through close_stash()
## makes this screen's visibility the single source of truth and fixes
## every such path at once, including any added later.
##
## No recursion risk: close_stash() clears current_stash BEFORE emitting
## stash_closed, so the _on_stash_closed() -> close() this triggers finds
## is_active() already false on the way back through here.
func _on_visibility_changed() -> void:
	if not visible and StashManager.is_active():
		StashManager.close_stash()


func _on_stash_opened(stash: StashComponent, _actor: Unit) -> void:
	_stash = stash
	if UIStack.is_open(party_overview):
		UIStack.pop(party_overview)
	_stash_title.text = stash.display_name
	stash.inventory.reparent(_stash_slot)
	stash.inventory.visible = true
	party_overview.get_inventory().reparent(_party_slot)
	open()


func _on_stash_closed() -> void:
	if is_instance_valid(_stash):
		_stash.inventory.visible = false
		_stash.inventory.reparent(_stash)
	party_overview.get_inventory().reparent(party_overview.get_inventory_slot())
	close()
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
