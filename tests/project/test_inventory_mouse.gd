extends AiTestCase
## The inventory's mouse work: an item lights up from the mouse entering and
## leaving it, and a drag at the edge scrolls by the physics step, the same
## distance a tick at any frame rate.

const INVENTORY = preload("res://systems/inventory_system/inventory.tscn")
const ITEM = preload("res://systems/inventory_system/item.tscn")


func run() -> void:
	var inventory: Inventory = INVENTORY.instantiate()
	add_child(inventory)
	inventory.position = Vector2.ZERO
	inventory.size = Vector2(160, 160)
	var item: Item = ITEM.instantiate()
	inventory.bind(ItemContainer.new(60, 60))
	inventory.item_layer.add_child(item)
	item.position = Vector2(10, 10)
	item.instance = ItemInstance.new()
	await get_tree().process_frame

	_hover(Vector2(55, 55))
	check("an item at rest is dim", is_equal_approx(item.background.color.a, Item.BACKGROUND_ALPHA), str(item.background.color.a))
	_hover(item.global_position + Vector2(5, 5))
	check("the mouse on it lights it", is_equal_approx(item.background.color.a, Item.BACKGROUND_ALPHA_HOVERED), str(item.background.color.a))
	_hover(item.global_position + item.size - Vector2(5, 5))
	check("moving across it keeps it lit", is_equal_approx(item.background.color.a, Item.BACKGROUND_ALPHA_HOVERED), str(item.background.color.a))
	_hover(Vector2(55, 55))
	check("the mouse leaving dims it", is_equal_approx(item.background.color.a, Item.BACKGROUND_ALPHA), str(item.background.color.a))

	var scroll: ScrollContainer = inventory.scroll_container
	var mouse: Vector2 = scroll.get_local_mouse_position()
	check("the headless mouse sits on the top-left edge", mouse == Vector2.ZERO, str(mouse))
	var cap: int = Engine.max_fps
	for fps: int in [20, 144]:
		Engine.max_fps = fps
		scroll.scroll_vertical = 1000
		inventory.update_ghost_preview(item, Vector2i.ZERO)
		await get_tree().physics_frame
		var from: int = scroll.scroll_vertical
		for tick: int in 6:
			await get_tree().physics_frame
		check("at %d fps a tick at the edge scrolls 10 px" % fps, from - scroll.scroll_vertical == 60, str(from - scroll.scroll_vertical))
		inventory.hide_ghost_preview()
	Engine.max_fps = cap
	var stopped_at: int = scroll.scroll_vertical
	await get_tree().physics_frame
	await get_tree().physics_frame
	check("it stops when the drag leaves", scroll.scroll_vertical == stopped_at)

	inventory.free()


func _hover(at: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	get_viewport().push_input(motion)
