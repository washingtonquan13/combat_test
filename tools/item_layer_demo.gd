extends Node
## Standalone recorded walkthrough — NOT a test, NOT part of tests/run.sh.
## Boots the real game (MainRoot.tscn), makes a character, walks into
## test_arena and drives the item layer through the real UI: loot a chest,
## drag items around the grid and onto/off equip slots, right-click
## Equip/Drop, switch the viewed unit, Sort, dialogue item effects, then
## save, load and new game. Every step prints PASS/FAIL and the screen
## carries a caption, so a Movie Maker recording reads on its own.
##
## Run with a real rendering driver, e.g.
##   Godot --rendering-driver opengl3 --resolution 1600x900 \
##     --write-movie out.avi --fixed-fps 30 res://tools/item_layer_demo.tscn
##
## Mouse input is synthetic (Input.parse_input_event), so drags go through
## Godot's own drag-and-drop exactly as a player's would. The OS cursor is
## warped along with it (it moves on screen while this runs) but is not in
## a recording; a drawn arrow stands in for it.

const MainRootScene: PackedScene = preload("res://MainRoot.tscn")
const IronSword: ItemDefinition = preload("res://data/items/iron_sword.tres")
const SAVE_NAME := "item_layer_demo"

var _caption: Label
var _cursor: Polygon2D
var _mouse := Vector2.ZERO
var _passed := 0
var _failed: Array[String] = []


func _ready() -> void:
	Input.use_accumulated_input = false
	_build_overlay()
	add_child(MainRootScene.instantiate())
	_run.call_deferred()


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	await _loot_chest()
	var overview: Node = get_tree().get_first_node_in_group("party_overview")
	var hero: Unit = PartyManager.leader
	overview.open_for(hero)
	await _wait(1.0)
	await _drag_in_grid(overview)
	await _drag_onto_slot_and_back(overview, hero)
	await _context_menu_equip_and_drop(overview, hero)
	await _switch_units(overview, hero)
	await _sort(overview)
	await _dialogue_effects()
	overview.close()
	await _wait(0.5)
	await _save_and_load()
	await _new_game()

	var total := _passed + _failed.size()
	_say("Done: %d/%d checks passed" % [_passed, total])
	print("DEMO RESULT: %d/%d passed" % [_passed, total])
	for f in _failed:
		print("  FAILED: ", f)
	await _wait(3.0)
	get_tree().quit()


# --- Steps ---

func _boot_into_arena() -> void:
	_say("Title screen -> Start -> auto-filled character")
	await _wait(1.5)
	get_tree().get_first_node_in_group("main_menu")._on_start_pressed()
	await _wait(1.0)
	var creation: Node = get_tree().get_first_node_in_group("character_creation")
	creation._on_auto_fill_pressed()
	await _wait(1.5)
	creation._on_confirm_pressed()
	await WorldManager.world_focused
	await _wait(2.5)
	_check("arrived in test_arena with an active unit",
		PartyManager.leader != null)
	_check("party bag starts empty", PartyManager.inventory.items().is_empty())


func _loot_chest() -> void:
	_say("Open the chest, press Take All")
	var chest: Node = get_tree().root.find_child("Chest", true, false)
	var stash: StashComponent = StashComponent.find_on(chest)
	StashManager.open_stash(stash, PartyManager.leader)
	await _wait(1.5)
	var chest_bag: ItemContainer = stash.inventory.get_container()
	var looted := chest_bag.items().size()
	_check("chest holds items (%d)" % looted, looted > 0)
	var panel: Node = get_tree().root.find_child("StashPanel", true, false)
	var take_all: Button = panel.get_node("%TakeAllButton") if panel else null
	if take_all:
		await _click(_center(take_all))
	await _wait(1.5)
	_check("Take All moved every chest item into the party bag",
		chest_bag.items().is_empty() and PartyManager.inventory.items().size() == looted)
	StashManager.close_stash()
	await _wait(0.8)
	var reopened := ItemContainer.new()
	reopened.load_state(stash.inventory.get_container().save_state())
	_check("chest stays empty after close", reopened.items().is_empty())


func _drag_in_grid(overview: Node) -> void:
	_say("Drag an item to another cell")
	var bag := PartyManager.inventory
	var inventory: Inventory = overview.get_inventory()
	var item: ItemInstance = bag.find_definition(IronSword)
	if not item:
		item = bag.items()[0]
	var from: Vector2 = await _widget_center(inventory, item)
	var target := _last_free_cell(bag, item)
	await _drag(from, _cell_center.bind(inventory, item, target))
	await _wait(0.8)
	_check("dragged item now sits at %s" % target, bag.cell_of(item) == target)
	_check("the grid shows one widget per item",
		_widgets(inventory).size() == bag.items().size())
	_check("every widget is drawn at its footprint times the grid's cell size",
		_widgets(inventory).all(func(w: Item) -> bool:
			return w.size == Vector2(w.get_cell_size() * inventory.cell_size_px)))


func _drag_onto_slot_and_back(overview: Node, hero: Unit) -> void:
	_say("Drag a helmet onto the helmet slot")
	var bag := PartyManager.inventory
	var inventory: Inventory = overview.get_inventory()
	var slot := _slot(EquipSlot.Slot.HELMET)
	var helmet := _first_for(bag, slot)
	if not helmet:
		_check("bag has a helmet to equip", false)
		return
	await _drag(await _widget_center(inventory, helmet), _center(slot))
	await _wait(0.8)
	_check("helmet is worn by the hero, out of the bag",
		hero.get_equipped_item(EquipSlot.Slot.HELMET) == helmet and not bag.has_instance(helmet))
	_check("helmet slot shows it",
		slot.equipped_item != null and slot.equipped_item.instance == helmet)

	_say("Drag it back into the bag")
	var target := _last_free_cell(bag, helmet)
	await _drag(_center(slot), _cell_center.bind(inventory, helmet, target))
	await _wait(0.8)
	_check("helmet back in the bag at %s, slot empty" % target,
		bag.cell_of(helmet) == target and hero.get_equipped_item(EquipSlot.Slot.HELMET) == null)


func _context_menu_equip_and_drop(overview: Node, hero: Unit) -> void:
	_say("Right-click boots -> Equip")
	var bag := PartyManager.inventory
	var inventory: Inventory = overview.get_inventory()
	var boots := _first_for(bag, _slot(EquipSlot.Slot.BOOTS))
	if boots:
		await _context_menu_pick(await _widget_center(inventory, boots), "Equip")
		_check("boots equipped from the context menu",
			hero.get_equipped_item(EquipSlot.Slot.BOOTS) == boots and not bag.has_instance(boots))

	_say("Right-click an item -> Drop")
	var victim: ItemInstance = null
	for item in bag.items():
		if item.gear_data == null or item.definition != IronSword:
			victim = item
			break
	if victim:
		var before := bag.items().size()
		await _context_menu_pick(await _widget_center(inventory, victim), "Drop")
		_check("Drop removed it from the bag and the grid",
			not bag.has_instance(victim) and bag.items().size() == before - 1
			and _widgets(inventory).size() == bag.items().size())


func _switch_units(overview: Node, hero: Unit) -> void:
	var other: Unit = null
	for unit in get_tree().get_nodes_in_group("units"):
		if unit != hero and unit is Unit:
			other = unit
			break
	if not other:
		for node in get_tree().root.find_children("*", "", true, false):
			if node is Unit and node != hero:
				other = node
				break
	if not other:
		_check("another unit to view", false)
		return
	_say("View another unit (%s), then back" % other.name)
	overview.open_for(other)
	await _wait(1.5)
	_check("slots show the other unit's gear, not the hero's", _slots_match(other))
	overview.open_for(hero)
	await _wait(1.5)
	_check("back on the hero: boots still shown and worn",
		_slots_match(hero) and hero.get_equipped_item(EquipSlot.Slot.BOOTS) != null)


func _sort(overview: Node) -> void:
	_say("Press Sort")
	var bag := PartyManager.inventory
	var before := bag.items().size()
	await _click(_center(overview.get_node("%SortButton")))
	await _wait(1.0)
	var origin_used := false
	for item in bag.items():
		if bag.cell_of(item) == Vector2i.ZERO:
			origin_used = true
	_check("Sort kept every item (%d) and packed from the top-left" % before,
		bag.items().size() == before and origin_used)


func _dialogue_effects() -> void:
	_say("Dialogue effects: give a sword, check it, sacrifice it")
	var bag := PartyManager.inventory
	var before := _count(bag, IronSword)
	var give := GiveItemEffect.new()
	give.gear_data = IronSword
	give.apply(null)
	await _wait(1.0)
	_check("GiveItemEffect added a sword (%d -> %d)" % [before, _count(bag, IronSword)],
		_count(bag, IronSword) == before + 1)
	var owned := ItemOwnedPrerequisite.new()
	owned.gear_data = IronSword
	_check("ItemOwnedPrerequisite sees it", owned.is_satisfied(null))
	var sacrifice := SacrificeItemEffect.new()
	sacrifice.gear_data = IronSword
	sacrifice.apply(null)
	await _wait(1.0)
	_check("SacrificeItemEffect took one back", _count(bag, IronSword) == before)


func _save_and_load() -> void:
	_say("Save, empty the bag, load")
	var bag := PartyManager.inventory
	var hero: Unit = PartyManager.leader
	var saved_bag := _snapshot(bag)
	var saved_boots: ItemDefinition = hero.get_equipped_item(EquipSlot.Slot.BOOTS).definition \
		if hero.get_equipped_item(EquipSlot.Slot.BOOTS) else null
	_check("save written", SaveManager.save(SAVE_NAME))
	var path := ""
	for entry in SaveManager.list_saves():
		if entry["name"] == SAVE_NAME:
			path = entry["path"]
			break
	bag.clear()
	await _wait(0.5)
	_check("load accepted", path != "" and SaveManager.load_file(path))
	await _wait(3.0)
	_check("bag restored item for item, cell for cell", _snapshot(PartyManager.inventory) == saved_bag)
	var hero_after: Unit = PartyManager.leader
	var boots_after: ItemInstance = hero_after.get_equipped_item(EquipSlot.Slot.BOOTS) if hero_after else null
	_check("hero still wears the boots after load",
		saved_boots != null and boots_after != null and boots_after.definition == saved_boots)
	var overview: Node = get_tree().get_first_node_in_group("party_overview")
	if hero_after:
		overview.open_for(hero_after)
		await _wait(2.0)
		_check("loaded bag is drawn on screen",
			overview.get_inventory().is_visible_in_tree()
			and _widgets(overview.get_inventory()).size() == PartyManager.inventory.items().size())
		overview.close()
		await _wait(0.5)
	if path != "":
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _new_game() -> void:
	_say("New game: the bag must be empty")
	_check("new_game accepted", SaveManager.new_game())
	await _wait(1.5)
	_check("bag empty after new game", PartyManager.inventory.items().is_empty())


# --- Helpers ---

func _check(what: String, ok: bool) -> void:
	print("%s  %s" % ["PASS" if ok else "FAIL", what])
	if ok:
		_passed += 1
	else:
		_failed.append(what)
	_caption.text = _caption.text.get_slice("\n", 0) + "\n" + ("✓ " if ok else "✗ ") + what


func _say(text: String) -> void:
	print("== ", text)
	_caption.text = text


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 127
	add_child(layer)
	var band := PanelContainer.new()
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	band.position = Vector2(20, 20)
	layer.add_child(band)
	_caption = Label.new()
	_caption.add_theme_font_size_override("font_size", 26)
	band.add_child(_caption)
	_cursor = Polygon2D.new()
	_cursor.polygon = PackedVector2Array([Vector2(0, 0), Vector2(0, 26), Vector2(7, 19),
		Vector2(12, 30), Vector2(16, 28), Vector2(11, 18), Vector2(20, 18)])
	_cursor.color = Color.WHITE
	var outline := Line2D.new()
	outline.points = _cursor.polygon
	outline.closed = true
	outline.width = 2.0
	outline.default_color = Color.BLACK
	_cursor.add_child(outline)
	layer.add_child(_cursor)


func _motion(to: Vector2, mask: int) -> void:
	var event := InputEventMouseMotion.new()
	event.position = to
	event.global_position = to
	event.relative = to - _mouse
	event.button_mask = mask
	_mouse = to
	_cursor.position = to
	# The grid's edge autoscroll reads the real cursor
	# (get_local_mouse_position), not the event, so the OS cursor has to
	# be where the synthetic one is.
	Input.warp_mouse(to)
	Input.parse_input_event(event)


func _button(index: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = _mouse
	event.global_position = _mouse
	event.button_index = index
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if (pressed and index == MOUSE_BUTTON_LEFT) else 0
	Input.parse_input_event(event)


func _glide(to: Vector2, mask: int, frames: int = 20) -> void:
	var from := _mouse
	for i in range(1, frames + 1):
		_motion(from.lerp(to, float(i) / frames), mask)
		await get_tree().process_frame


func _click(at: Vector2, index: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	await _glide(at, 0)
	await _wait(0.2)
	_button(index, true)
	await get_tree().process_frame
	_button(index, false)
	await _wait(0.3)


## `to` may be a Callable returning the point, re-asked after the glide:
## the grid scrolls under a drag near its edge, so a cell's screen position
## is only known at the moment of release.
func _drag(from: Vector2, to: Variant) -> void:
	await _glide(from, 0)
	await _wait(0.3)
	_button(MOUSE_BUTTON_LEFT, true)
	await get_tree().process_frame
	await _glide(to.call() if to is Callable else to, MOUSE_BUTTON_MASK_LEFT, 30)
	await _wait(0.3)
	if to is Callable:
		await _glide(to.call(), MOUSE_BUTTON_MASK_LEFT, 4)
		await _wait(0.2)
	_button(MOUSE_BUTTON_LEFT, false)
	await get_tree().process_frame


## Right-clicks the widget at `at`, then left-clicks the named button of
## the popup that opens. Reports a failed check when no menu appeared.
func _context_menu_pick(at: Vector2, button_name: String) -> void:
	await _click(at, MOUSE_BUTTON_RIGHT)
	await _wait(0.5)
	var menu: Window = null
	for child in get_tree().root.get_children():
		if child is PopupPanel and child.visible:
			menu = child
	_check("right-click opened the context menu", menu != null)
	if not menu:
		return
	var button: Button = menu.get_node("VBoxContainer/" + button_name)
	await _click(Vector2(menu.position) + button.get_global_rect().get_center())
	await _wait(0.8)


func _center(control: Control) -> Vector2:
	return control.get_global_rect().get_center()


func _widgets(inventory: Inventory) -> Array[Item]:
	var found: Array[Item] = []
	var stack: Array[Node] = [inventory]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is Item and not node.is_queued_for_deletion():
			found.append(node)
		stack.append_array(node.get_children())
	return found


func _widget_center(inventory: Inventory, item: ItemInstance) -> Vector2:
	await get_tree().process_frame
	for widget in _widgets(inventory):
		if widget.instance == item:
			var scroll := widget.get_ancestor_scroll_container()
			if scroll:
				scroll.ensure_control_visible(widget)
				await get_tree().process_frame
				await get_tree().process_frame
			return _center(widget)
	push_warning("item_layer_demo: no widget for %s" % item.definition.id)
	return _mouse


func _grid_layer(inventory: Inventory) -> InventoryGridLayer:
	var layer: InventoryGridLayer = null
	var stack: Array[Node] = [inventory]
	while not stack.is_empty() and not layer:
		var node: Node = stack.pop_back()
		if node is InventoryGridLayer:
			layer = node
		stack.append_array(node.get_children())
	return layer


func _cell_rect(inventory: Inventory, item: ItemInstance, cell: Vector2i) -> Rect2:
	var layer := _grid_layer(inventory)
	var px: float = layer.cell_size_px
	return Rect2(layer.get_global_rect().position + Vector2(cell) * px, Vector2(item.size()) * px)


## Where to release so item lands at cell: a drop puts the item's top-left
## on the cell under the cursor.
func _cell_center(inventory: Inventory, item: ItemInstance, cell: Vector2i) -> Vector2:
	var px: float = _grid_layer(inventory).cell_size_px
	return _cell_rect(inventory, item, cell).position + Vector2(px, px) / 2.0


## The free cell furthest from the top-left that is fully on screen — the
## grid scrolls, and a drop can only land on the visible part of it.
func _last_free_cell(bag: ItemContainer, item: ItemInstance) -> Vector2i:
	var inventory: Inventory = get_tree().get_first_node_in_group("party_overview").get_inventory()
	var clip := _grid_layer(inventory).get_global_rect()
	var node: Node = _grid_layer(inventory)
	while node:
		if node is ScrollContainer:
			clip = node.get_global_rect()
			break
		node = node.get_parent()
	var calm := clip.grow(-64.0)
	for y in range(bag.height - item.size().y, -1, -1):
		for x in range(bag.width - item.size().x, -1, -1):
			if bag.fits(item, Vector2i(x, y)) and clip.encloses(_cell_rect(inventory, item, Vector2i(x, y))) 					and calm.has_point(_cell_center(inventory, item, Vector2i(x, y))):
				return Vector2i(x, y)
	return Vector2i(-1, -1)


func _slot(key: EquipSlot.Slot) -> EquipSlot:
	for slot in get_tree().get_nodes_in_group("equip_slots"):
		if slot.slot == key:
			return slot
	return null


func _first_for(bag: ItemContainer, slot: EquipSlot) -> ItemInstance:
	for item in bag.items():
		if slot.accepts(item):
			return item
	return null


func _slots_match(unit: Unit) -> bool:
	for slot in get_tree().get_nodes_in_group("equip_slots"):
		var worn: ItemInstance = unit.get_equipped_item(slot.slot)
		var shown: ItemInstance = slot.equipped_item.instance if slot.equipped_item else null
		if worn != shown:
			return false
	return true


func _count(bag: ItemContainer, definition: ItemDefinition) -> int:
	var n := 0
	for item in bag.items():
		if item.definition == definition:
			n += item.count
	return n


func _snapshot(bag: ItemContainer) -> Array:
	var rows: Array = []
	for entry in bag.save_state()["items"]:
		rows.append("%s@%d,%d x%d" % [entry["id"], entry["x"], entry["y"], entry["stack"]])
	rows.sort()
	return rows
