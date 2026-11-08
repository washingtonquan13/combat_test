extends AiTestCase
## A body wider than the distance field's 4 m reach (an SM 6 dragon) still
## finds open ground: past the reach it needs only "clear all the way
## out", where it once needed more than the field can ever say and could
## not move at all.


func run() -> void:
	var unit: Unit = spawn_unit(&"player", 10, 10, 10, [], Vector3.ZERO)
	await get_tree().physics_frame
	unit.radius = 4.5
	var path: PackedVector3Array = NavigationGrid.find_path(get_tree(), unit.global_position, unit.global_position + Vector3(4, 0, 0), unit, false, [])
	check("a 4.5 m wide body walks on open ground", path.size() >= 2, "path %d points" % path.size())
	free_spawned()
