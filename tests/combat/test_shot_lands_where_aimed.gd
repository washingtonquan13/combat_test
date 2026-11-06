extends AiTestCase
## A shot is traced from the caster's eye to the spot aimed at itself, and
## the aim line draws that same segment: it ends on the aimed point (the
## blast's centre) and starts clear of the body. It used to trace and draw
## both ends 1.5 m up, so a waist-high crate in front of the spot never
## blocked and the line floated above the cursor and the ring.


func run() -> void:
	var crate := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 1.0, 0.4)
	shape.shape = box
	shape.position = Vector3(0.0, 0.5, 0.0)
	crate.add_child(shape)
	_root.add_child(crate)
	var caster: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(0.0, 0.0, -4.0))
	await get_tree().physics_frame

	check("a waist-high crate hides the ground just behind it",
		not LineOfSight.has_clear_shot_to_point(caster, Vector3(0.0, 0.0, 1.0)))
	check("but not open ground beside it",
		LineOfSight.has_clear_shot_to_point(caster, Vector3(4.0, 0.0, -1.0)))

	var targeting := AreaTargeting.new()
	targeting.max_range = 20.0
	var ability := Ability.new()
	ability.targeting = targeting
	var indicator := preload("res://systems/indicator_system/area_indicator.gd").new()
	add_child(indicator)
	var aim := Aim.new()
	aim.caster = caster
	aim.ability = ability
	aim.point = Vector3(6.0, 0.0, -4.0)
	indicator.draw(aim)

	var bounds: AABB = indicator._line_mesh.get_aabb()
	check("the aim line comes down to the aimed point",
		bounds.position.y < aim.point.y + 0.15, "lowest %.2f" % bounds.position.y)
	check("and reaches it", bounds.grow(0.15).has_point(aim.point), "%s" % bounds)
	check("and starts clear of the eye",
		not bounds.grow(0.1).has_point(LineOfSight.shot_from(caster)), "%s" % bounds)
	indicator.queue_free()
