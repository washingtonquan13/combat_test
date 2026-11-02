class_name ItemContainer
extends RefCounted
## A grid of ItemInstances — which copy sits at which cell. The model
## under an Inventory widget: the widget draws it and turns drags into
## place()/remove() calls, but the contents live here, so they exist
## whether or not any widget is showing them (the party inventory is
## owned by PartyManager, not by the PartyOverview screen).
##
## Cells are top-left corners; an instance covers ItemInstance.size()
## cells from there.

signal item_added(item: ItemInstance)
signal item_removed(item: ItemInstance)
signal item_moved(item: ItemInstance)

var width: int
var height: int

var _cells: Dictionary = {}  # ItemInstance -> Vector2i


func _init(grid_width: int = 12, grid_height: int = 6) -> void:
	width = grid_width
	height = grid_height


func items() -> Array:
	return _cells.keys()


func has_instance(item: ItemInstance) -> bool:
	return _cells.has(item)


func cell_of(item: ItemInstance) -> Vector2i:
	return _cells.get(item, Vector2i(-1, -1))


## True when item would sit at cell inside the grid without overlapping
## anything else. item's own current cell doesn't count against it, so a
## move can overlap where it already is.
func fits(item: ItemInstance, cell: Vector2i) -> bool:
	return _fits_in(_cells, item, cell)


func place(item: ItemInstance, cell: Vector2i) -> bool:
	if not fits(item, cell):
		return false
	var moving := _cells.has(item)
	_cells[item] = cell
	if moving:
		item_moved.emit(item)
	else:
		item_added.emit(item)
	return true


func remove(item: ItemInstance) -> void:
	if _cells.erase(item):
		item_removed.emit(item)


## The first cell (row by row) item fits at, or (-1, -1) when it fits
## nowhere.
func first_free_cell(item: ItemInstance) -> Vector2i:
	return _first_free_in(_cells, item)


## Places item at its first free cell. False, and nothing changes, when
## the grid has no room.
func add(item: ItemInstance) -> bool:
	var cell := first_free_cell(item)
	if cell == Vector2i(-1, -1):
		return false
	return place(item, cell)


## Re-packs every item first-fit in reading order. The whole new layout
## is worked out before anything moves, and nothing moves if any item
## wouldn't fit, so a sort can never lose an item.
func sort() -> void:
	var order: Array = _cells.keys()
	order.sort_custom(func(a, b):
		var ca: Vector2i = _cells[a]
		var cb: Vector2i = _cells[b]
		if ca.y != cb.y:
			return ca.y < cb.y
		return ca.x < cb.x
	)
	var packed: Dictionary = {}
	for item in order:
		var cell := _first_free_in(packed, item)
		if cell == Vector2i(-1, -1):
			return
		packed[item] = cell
	for item in order:
		if packed[item] != _cells[item]:
			_cells[item] = packed[item]
			item_moved.emit(item)


func clear() -> void:
	for item in _cells.keys():
		remove(item)


func find_definition(definition: ItemDefinition) -> ItemInstance:
	for item in _cells:
		if item.definition == definition:
			return item
	return null


func has(definition: ItemDefinition) -> bool:
	return find_definition(definition) != null


## Takes one from the first matching stack, removing the instance once
## its stack is spent. False, and nothing changes, if nothing matched —
## SacrificeItemEffect needs to tell the two apart.
func consume(definition: ItemDefinition) -> bool:
	var item := find_definition(definition)
	if not item:
		return false
	if item.count > 1:
		item.count -= 1
	else:
		remove(item)
	return true


## --- Save/load ---
## Same {"items": [{id, x, y, stack}]} shape Inventory always wrote, so
## existing saves load unchanged. Item identity is ItemDefinition.id, not
## a resource path — the same reason ItemDatabase keys everything by id.
## An empty Dictionary from a stash means "nothing worth recording" (see
## AreaState.stored_state()).
func save_state() -> Dictionary:
	var entries: Array[Dictionary] = []
	for item in _cells:
		if item.definition:
			var cell: Vector2i = _cells[item]
			var entry: Dictionary = item.to_dict()
			entry["x"] = cell.x
			entry["y"] = cell.y
			entries.append(entry)
	return {"items": entries}


func load_state(state: Dictionary) -> void:
	clear()
	for entry in state.get("items", []):
		var item := ItemInstance.from_dict(entry)
		if not item:
			push_warning("ItemContainer.load_state: unknown item id '%s'" % entry.get("id"))
			continue
		var cell := Vector2i(entry.get("x", 0), entry.get("y", 0))
		if not place(item, cell):
			push_warning("ItemContainer.load_state: '%s' doesn't fit at %s" % [item.definition.id, cell])


func _fits_in(cells: Dictionary, item: ItemInstance, cell: Vector2i) -> bool:
	var rect := Rect2i(cell, item.size())
	if not Rect2i(Vector2i.ZERO, Vector2i(width, height)).encloses(rect):
		return false
	for other in cells:
		if other == item:
			continue
		if rect.intersects(Rect2i(cells[other], other.size())):
			return false
	return true


func _first_free_in(cells: Dictionary, item: ItemInstance) -> Vector2i:
	var footprint := item.size()
	for y in range(height - footprint.y + 1):
		for x in range(width - footprint.x + 1):
			if _fits_in(cells, item, Vector2i(x, y)):
				return Vector2i(x, y)
	return Vector2i(-1, -1)
