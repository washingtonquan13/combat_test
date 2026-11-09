extends AiTestCase
## A crawler's route goes up a wall and across a ceiling; a walker's never
## leaves the floor.

## Deliberately off the 0.25 m cell boundary: the grid can only round it.
const WALL_FACE_Z: float = 5.66
const CEILING_Y: float = 4.0


func run() -> void:
	var wall: StaticBody3D = _solid(Vector3(0.0, 3.0, WALL_FACE_Z + 0.25), Vector3(12.0, 6.0, 0.5))
	var slab: StaticBody3D = _solid(Vector3(0.0, CEILING_Y + 0.2, 4.0), Vector3(8.0, 0.4, 4.0))
	await get_tree().physics_frame
	await get_tree().physics_frame
	NavigationGrid.invalidate()

	var definition: UnitDefinition = load("res://data/units/beasts/giant_spider.tres")
	var spider: Unit = definition.unit_scene.instantiate()
	spider.definition = definition
	spider.faction = &"player"
	_root.add_child(spider)
	spider.global_position = Vector3.ZERO
	await get_tree().physics_frame
	var walker: Unit = spawn_unit(&"player", 10, 10, 10, [], Vector3(3.0, 0.0, 0.0))

	check("the Clinging advantage makes it a crawler", spider.can_crawl())
	check("an ordinary unit is not one", not walker.can_crawl())

	var on_wall: Vector3 = Vector3(-3.0, 2.5, WALL_FACE_Z)
	var up_wall: PackedVector3Array = NavigationGrid.find_crawl_path(get_tree(), spider.global_position, on_wall, spider)
	check("a route reaches the wall", not up_wall.is_empty())
	if not up_wall.is_empty():
		var end: Vector3 = up_wall[up_wall.size() - 1]
		check("it ends up the wall, against it", end.y > 1.2 and absf(WALL_FACE_Z - end.z) < 1.2, str(end))
		check("near where it was asked to go", absf(end.x - on_wall.x) < 0.75, str(end))
		var surface: Dictionary = CrawlPose.surface_at(spider, end)
		var contact: Vector3 = surface.get("point", Vector3.ZERO)
		check("the surface it clings to is the wall's true face", absf(contact.z - WALL_FACE_Z) < 0.01, str(contact))

	var overhead: Vector3 = Vector3(0.0, CEILING_Y - 0.1, 4.0)
	var to_ceiling: PackedVector3Array = NavigationGrid.find_crawl_path(get_tree(), spider.global_position, overhead, spider)
	check("a route reaches the ceiling", not to_ceiling.is_empty())
	if not to_ceiling.is_empty():
		var end: Vector3 = to_ceiling[to_ceiling.size() - 1]
		check("it ends hanging from it", end.y + spider.height > CEILING_Y - 0.5, str(end))

	var plain: PackedVector3Array = NavigationGrid.find_path(get_tree(), walker.global_position, on_wall, walker, false)
	var highest: float = 0.0
	for point: Vector3 in plain:
		highest = maxf(highest, point.y)
	check("a walker sent at the wall stays on the floor", highest < 0.5, "highest %.2f" % highest)

	var cling: Ability = load("res://data/abilities/cling.tres")
	check("Cling is on from the start", spider.is_toggled(cling) and spider.abilities.has(cling))
	spider.move_to(on_wall)
	await get_tree().physics_frame
	check("sent up the wall", spider.is_moving())
	spider.set_toggled(cling, false)
	await get_tree().physics_frame
	check("switched off, it stops: that route was a crawler's", not spider.is_moving())
	check("switched off, it is no crawler", not spider.can_crawl())

	spider.set_toggled(cling, true)
	var high: Vector3 = up_wall[up_wall.size() - 1]
	spider.global_position = high
	for i in 20:
		await get_tree().physics_frame
	check("switched on, it holds the wall", absf(spider.global_position.y - high.y) < 0.05, str(spider.global_position))
	spider.set_toggled(cling, false)
	for i in 90:
		await get_tree().physics_frame
	check("switched off on the wall, it drops", spider.global_position.y < 0.3, str(spider.global_position))

	var summon: Ability = load("res://data/abilities/summon_giant_spider.tres")
	summon.effects[0].apply(walker, Vector3(-3.0, 0.0, 0.0), summon, false)
	var summoned: Unit = null
	for sibling in walker.get_parent().get_children():
		if sibling is Unit and sibling.summoned_by == walker:
			summoned = sibling
	check("the summon makes a spider on the caster's side", summoned != null and summoned.faction == walker.faction)
	check("summoned, it is already a crawler", summoned != null and summoned.can_crawl())
	if summoned:
		summoned.queue_free()
	StartingParty._give_everything(walker)
	check("the leader gets the summon", walker.abilities.has(summon))
	check("but not Cling, which needs the advantage", not walker.abilities.has(cling))

	spider.queue_free()
	free_spawned()
	wall.queue_free()
	slab.queue_free()


func _solid(center: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	_root.add_child(body)
	body.global_position = center
	return body
