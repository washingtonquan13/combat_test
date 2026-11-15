extends AiTestCase
## A dialogue stands its two people on the scene template's marks by showing
## a StandIn of each there, and never moves the units themselves: they are
## where they were, facing where they faced, with their own bodies hidden
## until the talk ends.

const Driver := preload("res://tests/conversation/conversation_driver.gd")

var d: Driver


func run() -> void:
	d = Driver.new()
	add_child(d)
	d.begin()
	var stand_ins := DialogueStandIns.new()
	_root.add_child(stand_ins)

	# Well inside talking reach, off to one side, neither facing the other.
	var ada: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(1.6, 0, 4.2))
	var brom: Unit = spawn_unit(&"neutral", 10, 10, 10, [melee()], Vector3(0, 0, 3))
	await get_tree().physics_frame
	var ada_was: Transform3D = ada.global_transform
	var brom_was: Transform3D = brom.global_transform
	var ada_body := ada.get_node("CharacterModel") as CharacterModel
	var template := DialogueStandIns.TEMPLATE.instantiate() as SceneTemplate
	var apart: float = (template.marks()[&"player"] as Transform3D).origin.length()
	template.free()

	d.start_dialogue(d.node("t_stand", "Hello.", [d.line("Bye.")]), {"player": ada, "npc": brom})
	var ada_stand: StandIn = StandIn.of(ada)
	var brom_stand: StandIn = StandIn.of(brom)
	check("both people in a dialogue get a stand-in", ada_stand != null and brom_stand != null)
	if ada_stand == null or brom_stand == null:
		stand_ins.queue_free()
		d.finish()
		return
	check("the one spoken to is shown where they stand",
		brom_stand.global_position.distance_to(brom.global_position) < 0.01)
	var gap: Vector3 = ada_stand.global_position - brom_stand.global_position
	gap.y = 0.0
	check("the one who came up is shown on the mark, not where the walk stopped",
		absf(gap.length() - apart) < 0.01, "%.2f m apart, the mark is %.2f" % [gap.length(), apart])
	check("on the side they came from",
		gap.normalized().dot((ada.global_position - brom.global_position).normalized()) > 0.9)
	check("and the two are turned to each other",
		ada_stand.visual_forward().dot(-gap.normalized()) > 0.99
		and brom_stand.visual_forward().dot(gap.normalized()) > 0.99)
	check("the units themselves have not moved or turned",
		ada.global_transform.is_equal_approx(ada_was) and brom.global_transform.is_equal_approx(brom_was))
	check("their own bodies are off screen", not ada_body.is_visible_in_tree())
	check("and the copy is on it", ada_stand.body() != null and ada_stand.body().is_visible_in_tree())

	var cast := SceneCast.new().track_unit(&"speaker", ada)
	var shot := CameraFraming.new()
	check("the camera frames the stand-in, not the unit",
		shot.look_of(shot._read_source(cast, &"", &"speaker")).distance_to(
			ada_stand.anchor(CharacterModel.Anchor.HEAD)) < 0.01)

	d.end_dialogue()
	check("ending the talk strikes the stand-ins", StandIn.of(ada) == null and StandIn.of(brom) == null)
	check("and puts the bodies back", ada_body.is_visible_in_tree())
	check("with the units still where they were",
		ada.global_transform.is_equal_approx(ada_was) and brom.global_transform.is_equal_approx(brom_was))

	stand_ins.queue_free()
	d.finish()
