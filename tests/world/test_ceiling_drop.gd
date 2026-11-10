extends AiTestCase
## Spiders hanging from the spider cave's roof stay there, and a fight
## brings them straight down to the floor unhurt.

## Where the cave's spiders hang (x, z), the same spots spider_cave.tscn uses.
const SPOTS: Array[Vector2] = [Vector2(-6, -3), Vector2(3, -6), Vector2(0, -12), Vector2(-4, -9)]


func run() -> void:
	var rock: Node3D = load("res://world/spider_cave/rock.scn").instantiate()
	_root.add_child(rock)
	await get_tree().physics_frame
	await get_tree().physics_frame
	NavigationGrid.invalidate()

	var definition: UnitDefinition = load("res://data/units/beasts/giant_spider.tres")
	for spot in SPOTS:
		var spider: Unit = definition.unit_scene.instantiate()
		spider.definition = definition
		_root.add_child(spider)
		spider.global_position = Vector3(spot.x, 0.5, spot.y)
		await get_tree().physics_frame
		var up := PhysicsRayQueryParameters3D.create(Vector3(spot.x, 1.0, spot.y), Vector3(spot.x, 30.0, spot.y))
		up.hit_back_faces = false
		up.exclude = [spider.get_rid()]
		var roof: Dictionary = spider.get_world_3d().direct_space_state.intersect_ray(up)
		check("a roof over %s" % spot, not roof.is_empty())
		var under: Vector3 = roof.get("position", Vector3(spot.x, 10.0, spot.y)) + Vector3.DOWN * 0.1
		var route: PackedVector3Array = NavigationGrid.find_crawl_path(get_tree(), spider.global_position, under, spider)
		check("a route up to the roof at %s" % spot, not route.is_empty())
		if route.is_empty():
			spider.queue_free()
			continue
		var hang: Vector3 = route[route.size() - 1]
		print("    hang %s -> %s" % [spot, hang])
		spider.global_position = hang
		for i in 30:
			await get_tree().physics_frame
		check("it holds the roof at %s" % spot, spider.held_surface_normal().y < -0.5 and absf(spider.global_position.y - hang.y) < 0.05, str(spider.global_position))

		var eye: Vector3 = spider.anchor(CharacterModel.Anchor.EYE)
		check("it watches from under the roof, not inside it", eye.y < under.y, "eye %.2f, roof %.2f" % [eye.y, under.y + 0.1])
		print("    facing %s" % spider.visual_forward())

		var dropper := CeilingDrop.new()
		spider.add_child(dropper)
		var health: int = spider.get_pool(StatIds.HP)
		check("it lets go", dropper.drop())
		for i in 150:
			await get_tree().physics_frame
		check("it lands on the floor", spider.global_position.y < 1.0 and spider.is_on_floor(), str(spider.global_position))
		check("unhurt", spider.get_pool(StatIds.HP) == health, "%d -> %d" % [health, spider.get_pool(StatIds.HP)])
		check("and is free to act", not spider.is_busy())
		check("on the floor a fight starting does nothing", not dropper.drop())
		spider.remove_from_group(&"units")
		spider.queue_free()
	rock.queue_free()
