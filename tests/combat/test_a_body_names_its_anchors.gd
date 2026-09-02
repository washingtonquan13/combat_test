extends AiTestCase
## A body says where its head and eyes are, and everything that aims at a
## creature asks it instead of guessing.
##
## Eye height was declared in five places — LineOfSight's default
## parameter, AreaTargeting's export, DetectionManager's constant, and two
## indicator offsets — all saying 1.5, for every creature. One of those
## carried a comment promising it matched LineOfSight "so the drawn line
## reflects where the raycast actually checks", and MainRoot.tscn had since
## overridden it to 2.0. The line players saw was half a metre above the
## ray being tested.
##
## Three properties:
##
## 1. NOTHING MOVED. The fallback proportions reproduce the exact constants
##    the game already used — 1.7 for the face, 1.5 for the eye — so a body
##    that declares no anchors behaves precisely as it did.
## 2. A DECLARED ANCHOR WINS. Placed by hand, it beats any proportion.
## 3. IT REACHES GAMEPLAY. Line of sight traces from the anchor, so where a
##    creature's eyes are changes what it can see.

const HEAD := CharacterModel.Anchor.HEAD
const EYE := CharacterModel.Anchor.EYE
const GROUND := CharacterModel.Anchor.GROUND

var _wall: StaticBody3D = null


func run() -> void:
	_the_defaults_are_the_old_constants()
	await _a_declared_anchor_beats_the_proportion()
	await _sight_lines_come_from_the_eye()
	_cleanup()
	free_spawned()


func _the_defaults_are_the_old_constants() -> void:
	var unit: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3.ZERO)
	var base: float = unit.global_position.y

	check("the head anchor is still where FaceAnchor was, at 1.70",
		is_equal_approx(unit.anchor(HEAD).y - base, 1.7),
		"head at %.3f" % (unit.anchor(HEAD).y - base))
	check("and the eye is still LineOfSight's old 1.50",
		is_equal_approx(unit.anchor(EYE).y - base, 1.5),
		"eye at %.3f — every sight line in the game just moved" % (unit.anchor(EYE).y - base))
	check("and the ground anchor is the floor the unit stands on",
		is_equal_approx(unit.anchor(GROUND).y - base, 0.0))


## The point of anchors: a body whose head is nowhere near 85% of its
## height is framed where it actually is.
func _a_declared_anchor_beats_the_proportion() -> void:
	var unit: Unit = _spawn_wearing(_body_with_low_head())
	await get_tree().process_frame
	var base: float = unit.global_position.y

	check("a tall body with a low head is framed at the head it declared",
		is_equal_approx(unit.anchor(HEAD).y - base, 1.2),
		"head at %.3f — the proportion would have said %.2f" % [
			unit.anchor(HEAD).y - base, unit.height * 0.85])
	check("and the proportion would indeed have been wrong",
		not is_equal_approx(unit.height * 0.85, 1.2),
		"the fixture is not actually testing anything")


## The half that is not cosmetic. A wall tall enough to block a 1.5 m
## sight line but not a 4 m one.
func _sight_lines_come_from_the_eye() -> void:
	_wall = StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 2.5, 0.4)
	shape.shape = box
	shape.position = Vector3(0.0, 1.25, 0.0)
	_wall.add_child(shape)
	_root.add_child(_wall)
	_wall.global_position = Vector3(0.0, 0.0, 0.0)
	await get_tree().physics_frame

	var ordinary: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3(0.0, 0.0, -4.0))
	var tall: Unit = _spawn_wearing(_body_with_high_eye())
	tall.global_position = Vector3(0.0, 0.0, -4.0)
	await get_tree().physics_frame

	var target := Vector3(0.0, 0.0, 4.0)
	check("an ordinary body cannot see over a 2.5 m wall from 1.5 m",
		not LineOfSight.has_clear_shot_to_point(ordinary, target),
		"the wall is not blocking anything — the fixture is wrong")
	# Its height is an ordinary 2.0, so the proportion would put this eye at
	# 1.5 and block it. Only the declared anchor gets it over.
	check("but a body that declares its eyes at 4 m can",
		LineOfSight.has_clear_shot_to_point(tall, target),
		"the sight line still came from 1.5 m, so the anchor is not reaching gameplay")


func _body_with_low_head() -> PackedScene:
	return _packed(4.0, Vector3(0.0, 1.2, 0.0), Vector3(0.0, 1.0, 0.0))


## Ordinary HEIGHT, extraordinary EYE. That combination is deliberate: a
## tall body would clear the wall on its proportion alone, so the test
## would pass with anchors disabled entirely — which it did, until the
## sabotage run caught it.
func _body_with_high_eye() -> PackedScene:
	return _packed(2.0, Vector3(0.0, 1.7, 0.0), Vector3(0.0, 4.0, 0.0))


func _packed(body_height: float, head_at: Vector3, eye_at: Vector3) -> PackedScene:
	var model := CharacterModel.new()
	model.name = "AnchoredBody"
	model.height = body_height

	var head := Marker3D.new()
	head.name = "HeadAnchor"
	head.position = head_at
	model.add_child(head)
	head.owner = model
	model.head_anchor = head

	var eye := Marker3D.new()
	eye.name = "EyeAnchor"
	eye.position = eye_at
	model.add_child(eye)
	eye.owner = model
	model.eye_anchor = eye

	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	model.add_child(player)
	player.owner = model
	model.animation_player = player

	var packed := PackedScene.new()
	packed.pack(model)
	model.free()
	return packed


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


func _cleanup() -> void:
	if is_instance_valid(_wall):
		_wall.queue_free()
		_wall = null
