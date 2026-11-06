extends AiTestCase
## Magic Missile flies around a wall to the target's chest. Units fill
## their whole body height, so the launch point inside the caster's body
## used to be a blocked start cell: find_path returned nothing and the
## bolt flew a straight line through the wall.


func run() -> void:
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 3.0, 0.4)
	shape.shape = box
	shape.position = Vector3(0.0, 1.5, 0.0)
	wall.add_child(shape)
	_root.add_child(wall)
	var caster: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(0.0, 0.0, -5.0))
	var target: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3(0.0, 0.0, 5.0))
	await get_tree().physics_frame

	var ability: Ability = load("res://data/abilities/magic_missile.tres")
	var step: PathedProjectileStep = ability.get_pathed_projectile_step()
	var path: PackedVector3Array = step.route(caster, caster.global_position, target, target.global_position)
	var crossing: Vector3 = _crossing(path)
	check("the missile goes around the wall",
		absf(crossing.x) > 2.0 or crossing.y > 3.0, "crosses at %s, path %s" % [crossing, path])
	check("and ends on the target's chest",
		path[-1].distance_to(LineOfSight.shot_to(target)) < 0.05, "ends %s" % path[-1])


## Where the path crosses the wall's plane, z = 0.
func _crossing(path: PackedVector3Array) -> Vector3:
	for i in path.size() - 1:
		if signf(path[i].z) != signf(path[i + 1].z):
			var t: float = -path[i].z / (path[i + 1].z - path[i].z)
			return path[i].lerp(path[i + 1], t)
	return Vector3.ZERO
