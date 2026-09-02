extends AiTestCase
## A body declares how big it is, and the unit both plans and collides at
## that size.
##
## The navigation grid has read per-unit size all along — the C++ pulls
## `radius` and `avoidance_margin` off the unit by duck-typing and sweeps
## clearance across every Y-layer `height` spans — and nothing had ever
## authored anything but the one default. All 32 demons were 0.25 m across.
##
##     clearance      = radius + avoidance_margin
##     vertical_cells = ceil(height / CELL_SIZE)
##
## Two properties, and the FIRST one is the dangerous one:
##
## 1. DEFAULTS ARE UNCHANGED. This touches navigation inputs for every unit
##    in the game. `avoidance_margin` is the trap — unit.gd declares 0.15,
##    but unit.tscn has always overridden it to 0.25, so 0.25 is what every
##    unit has actually been navigating with. A body declaring the script
##    default would silently re-tune all movement, and every other test here
##    would still pass.
##
## 2. PLAN AND BODY AGREE. A unit that plans as a dragon and collides as a
##    demon is worse than one that does neither: the planner routes around
##    a body the physics does not have, and nothing reports it.


func run() -> void:
	_defaults_are_exactly_what_they_were()
	await _a_big_body_is_big_to_both_the_planner_and_the_physics()
	free_spawned()


## The byte-identical check. Written first on purpose.
func _defaults_are_exactly_what_they_were() -> void:
	var unit: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3.ZERO)

	check("the default body still plans at radius 0.25",
		is_equal_approx(unit.radius, 0.25), "radius is %.3f" % unit.radius)
	check("and still at avoidance_margin 0.25, not the script's 0.15",
		is_equal_approx(unit.avoidance_margin, 0.25),
		"avoidance_margin is %.3f — every unit's clearance just changed" % unit.avoidance_margin)
	check("and still at height 2.0",
		is_equal_approx(unit.height, 2.0), "height is %.3f" % unit.height)

	var shape: Shape3D = _shape_of(unit)
	check("and still collides as a 0.25 capsule",
		shape is CapsuleShape3D and is_equal_approx((shape as CapsuleShape3D).radius, 0.25),
		"collides as %s" % ("nothing" if shape == null else shape.get_class()))


func _a_big_body_is_big_to_both_the_planner_and_the_physics() -> void:
	var unit: Unit = _spawn_wearing(_big_body())
	await get_tree().process_frame

	check("a body that says it is 3 m across makes the unit 3 m across",
		is_equal_approx(unit.radius, 3.0), "radius is %.3f" % unit.radius)
	check("and its margin and height come with it",
		is_equal_approx(unit.avoidance_margin, 0.5) and is_equal_approx(unit.height, 8.0),
		"margin %.3f, height %.3f" % [unit.avoidance_margin, unit.height])

	# What the grid will actually plan with.
	var clearance: float = unit.radius + unit.avoidance_margin
	check("so the grid plans it 3.50 m of clearance instead of 0.40",
		is_equal_approx(clearance, 3.5), "clearance is %.2f" % clearance)

	# The half that is easy to forget, and silent when wrong.
	var shape: Shape3D = _shape_of(unit)
	check("and the body it collides with is the one the body authored",
		shape is CapsuleShape3D and is_equal_approx((shape as CapsuleShape3D).radius, 3.0),
		"plans at 3.00 but collides at %s — the planner would route around " % (
			"nothing" if not (shape is CapsuleShape3D) else "%.2f" % (shape as CapsuleShape3D).radius) +
		"a body the physics does not have")

	check("and the shape sits where the body put it",
		is_equal_approx(_shape_node(unit).position.y, 4.0),
		"shape origin at y=%.2f, authored at 4.00" % _shape_node(unit).position.y)


## Built in code rather than as a fixture scene, so the numbers under test
## are visible right here next to the assertions about them.
func _big_body() -> PackedScene:
	var model := CharacterModel.new()
	model.name = "BigBody"
	model.radius = 3.0
	model.avoidance_margin = 0.5
	model.height = 8.0

	var template := CollisionShape3D.new()
	template.name = "CollisionTemplate"
	var capsule := CapsuleShape3D.new()
	capsule.radius = 3.0
	capsule.height = 8.0
	template.shape = capsule
	template.position = Vector3(0.0, 4.0, 0.0)
	model.add_child(template)
	template.owner = model
	model.collision_shape = template

	# A body with no clips — Phase 1's case — so this suite is not also
	# depending on an animation library existing.
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	model.add_child(player)
	player.owner = model
	model.animation_player = player

	var packed := PackedScene.new()
	packed.pack(model)
	model.free()
	return packed


func _shape_node(unit: Unit) -> CollisionShape3D:
	return unit.get_node_or_null("CollisionShape3D") as CollisionShape3D


func _shape_of(unit: Unit) -> Shape3D:
	var node: CollisionShape3D = _shape_node(unit)
	return node.shape if node else null


func _spawn_wearing(model: PackedScene) -> Unit:
	var definition := UnitDefinition.new()
	definition.model_scene = model
	definition.max_hp = 20
	definition.faction = &"player"

	var unit: Unit = load("res://systems/unit_system/unit.tscn").instantiate()
	unit.definition = definition
	_root.add_child(unit)
	var abilities: Array[Ability] = [melee()]
	unit.abilities = abilities
	unit.reset_turn_actions()
	_spawned.append(unit)
	return unit
