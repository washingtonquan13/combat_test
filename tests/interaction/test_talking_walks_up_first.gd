extends AiTestCase
## A left click on someone friendly is a Talk, and a Talk from across the
## room walks up first (InteractionApproach): the conversation opens on
## arrival, within the verb's reach. A ground click on the way calls it off.

const Driver := preload("res://tests/conversation/conversation_driver.gd")
const ROUTER_SCRIPT: GDScript = preload("res://systems/indicator_system/ground_click_target.gd")

var d: Driver


func run() -> void:
	d = Driver.new()
	add_child(d)
	d.begin()
	var router: ClickRouter = ROUTER_SCRIPT.new()
	_spawn_parent().add_child(router)
	router.set_process(false)

	var ada: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(-1, 0, 3))
	var brom: Unit = spawn_unit(&"neutral", 10, 10, 10, [melee()], Vector3(7, 0, 3))
	d.give_dialogue(brom, d.node("t_walk", "Hello.", [d.line("Bye.")]))
	SelectionManager.select(ada, false)
	await get_tree().physics_frame
	var talk: InteractionOption = load("res://data/interactions/talk.tres")

	router.click_unit(brom)
	check("a click on a friendly NPC from afar starts no conversation yet", not d.dialogue_active())
	check("it sends the clicker walking up instead", InteractionApproach.of(ada) != null and not ada.current_route().is_empty())
	check("and does not attack", not brom.in_combat() and brom.get_pool(StatIds.HP) == 10)
	await _until(func() -> bool: return d.dialogue_active(), 8.0)
	check("on arrival the conversation opens", d.dialogue_active())
	check("having walked there", ada.global_position.x > 3.0, str(ada.global_position))
	check("from within talking reach", ada.edge_distance_to(brom) <= talk.reach + 0.05,
		"%.2f m" % ada.edge_distance_to(brom))
	d.end_dialogue()

	ada.global_position = Vector3(-6, 0, 3)
	await get_tree().physics_frame
	router.click_unit(brom)
	await get_tree().physics_frame
	router.command_move(Vector3(-6, 0, 7))
	await _until(func() -> bool: return not ada.is_moving(), 8.0)
	check("a move order on the way calls the talk off",
		InteractionApproach.of(ada) == null and not d.dialogue_active())

	router.queue_free()
	d.finish()


func _until(done: Callable, seconds: float) -> void:
	var left: float = seconds
	while not done.call() and left > 0.0:
		await get_tree().physics_frame
		left -= get_physics_process_delta_time()
