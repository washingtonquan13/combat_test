extends AiTestCase
## The city overworld stands on its imported model: the street under the
## start spawn and an elevated expressway both stop a ray dropped from the
## sky, and what stops it is the city glb's own collision.
##
## The other overworld suites load this scene but never touch its ground,
## so they stay green with the city taken out of it. This suite does not.
## The city is world/city_overworld/city.tscn, its parts city_N.glb, written by
## tools/blockout/city_gltf.py, made solid by Godot's import through the
## glTF "-col" and "-colonly" node suffixes.

const SCENE := "res://world/city_overworld.tscn"
## Above everything in New Orleans.
const SKY: float = 400.0
## The street slab under the start spawn is the top of Floor, at y = 0.
const START_XZ := Vector2(-3071.37, 2443.99)
## The I-10 motorway at the Pontchartrain Expressway interchange,
## measured by LiDAR at 13.31 m (way 607711821).
const DECK_XZ := Vector2(-4630.8, 2956.55)
const DECK_HEIGHT: float = 13.31


func run() -> void:
	var area: Node3D = load(SCENE).instantiate()
	# The ground is the subject, not the overworld's avatar and camera.
	area.set_script(null)
	_root.add_child(area)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var city: Node = area.get_node_or_null("CityGeometry")
	check("the overworld instances the city model", city != null and city.scene_file_path.ends_with("city.tscn"),
		"CityGeometry is %s" % (city.scene_file_path if city else "missing"))
	if city == null:
		area.free()
		return
	var bodies := city.find_children("*", "StaticBody3D", true, false)
	check("the import made the city solid", bodies.size() > 0, "%d static bodies" % bodies.size())

	var street := _drop(area, START_XZ)
	check("a ray at the start spawn lands on the city", _is_city(city, street), _say(street))
	if not street.is_empty():
		check("and on the street, at y 0", absf(street.position.y) < 0.6, _say(street))

	var deck := _drop(area, DECK_XZ)
	check("a ray at the interchange lands on the city", _is_city(city, deck), _say(deck))
	if not deck.is_empty():
		check("and on the deck, at its LiDAR height", absf(deck.position.y - DECK_HEIGHT) < 2.0, _say(deck))
	area.free()


func _drop(area: Node3D, xz: Vector2) -> Dictionary:
	var from := Vector3(xz.x, SKY, xz.y)
	var query := PhysicsRayQueryParameters3D.create(from, from - Vector3(0.0, SKY + 50.0, 0.0))
	return area.get_world_3d().direct_space_state.intersect_ray(query)


func _is_city(city: Node, hit: Dictionary) -> bool:
	return not hit.is_empty() and city.is_ancestor_of(hit.collider)


func _say(hit: Dictionary) -> String:
	if hit.is_empty():
		return "nothing hit"
	return "hit %s at %s" % [hit.collider.get_path(), hit.position]
