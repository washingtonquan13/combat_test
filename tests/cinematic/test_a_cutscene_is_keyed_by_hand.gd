extends AiTestCase
## A hand-keyed Cutscene plays through the same director as everything
## else: bodies in the scene do the acting, the real units stay put and
## hidden, and end where their bodies ended, played through or skipped.

const SCENE := "res://cinematics/townsperson_meeting.tscn"
const HERO := "res://data/units/companions/player_character.tres"
const TOWNSPERSON := "res://data/units/npcs/townsperson.tres"
## Where the scene leaves the townsperson, in front of the hero.
const ENDS_AHEAD := 1.4


func wants_world() -> bool:
	return true


func run() -> void:
	var scene: PackedScene = load(SCENE)
	for skipped: bool in [false, true]:
		var tag: String = "skipped" if skipped else "played"
		var hero: Unit = _spawn(HERO, Vector3(float(skipped) * 12.0, 0.0, 0.0))
		await get_tree().process_frame
		var began: Vector3 = hero.global_position
		var ahead: Vector3 = hero.visual_forward()
		var result: Array = []
		_play(scene, SceneCast.new().track_unit(&"Hero", hero), result)
		await get_tree().process_frame
		await get_tree().process_frame

		var stage := CinematicDirector._stage as Cutscene
		var visitor: Unit = _townsperson(hero)
		var role := stage.get_node("Townsperson") as CutsceneRole if stage else null
		check("%s: the scene brings the townsperson in" % tag, visitor != null and role != null)
		if visitor == null or role == null:
			CinematicDirector._cancel(false)
			continue
		_spawned.append(visitor)
		check("%s: the scene stands where the hero stands" % tag,
			_flat(stage.get_node("Hero").global_position).distance_to(_flat(began)) < 0.05,
			"hero role at %s" % stage.get_node("Hero").global_position)
		check("%s: the units are hidden and bodies in the scene act" % tag,
			not StandIn.body_of(hero).visible and not StandIn.body_of(visitor).visible
			and role.body != null and role.body.visible and role.body.get_parent() == role)
		var player: AnimationPlayer = role.body.resolve_animation_player()
		check("%s: the body plays the clip the Timeline keys" % tag,
			player != null and player.current_animation == "Locomotion/walk",
			"playing '%s'" % (player.current_animation if player else "no player"))

		if skipped:
			CinematicDirector._skip_requested = true
		else:
			var lines: int = 0
			while result.is_empty():
				if stage.is_waiting():
					lines += 1
					CinematicDirector._advance_requested = true
				await get_tree().process_frame
				await get_tree().process_frame
			check("played: both lines waited for the player", lines == 2, "%d waited" % lines)
		while result.is_empty():
			await get_tree().process_frame

		check("%s: the scene finished" % tag, result[0] == true)
		check("%s: the hero has not moved" % tag,
			hero.global_position.distance_to(began) < 0.1,
			"moved %.3f m" % hero.global_position.distance_to(began))
		var wanted: Vector3 = began + ahead * ENDS_AHEAD
		check("%s: the townsperson is where her body ended" % tag,
			_flat(visitor.global_position).distance_to(_flat(wanted)) < 0.6,
			"at %s, wanted %s" % [visitor.global_position, wanted])
		check("%s: she faces the hero" % tag,
			visitor.visual_forward().dot(-ahead) > 0.9,
			"facing %s" % visitor.visual_forward())
		check("%s: the units are shown again" % tag,
			StandIn.body_of(hero).visible and StandIn.body_of(visitor).visible)
		free_spawned()
		await get_tree().process_frame
	await _placed(scene)


## The same scene sitting in the area: played where it sits, twice, and
## still there afterwards.
func _placed(scene: PackedScene) -> void:
	var hero: Unit = _spawn(HERO, Vector3(30.0, 0.0, 0.0))
	var placed := scene.instantiate() as Cutscene
	_spawn_parent().add_child(placed)
	placed.global_position = hero.global_position
	await get_tree().process_frame
	check("placed: out of sight until it plays", not placed.is_visible_in_tree())
	for turn in 2:
		var result: Array = []
		_play_placed(placed, SceneCast.new().track_unit(&"Hero", hero), result)
		await get_tree().process_frame
		await get_tree().process_frame
		var acting := CinematicDirector._stage as Cutscene
		check("placed %d: a copy acts, in sight, beside the placed one" % turn,
			acting != null and acting != placed and acting.is_visible_in_tree()
			and acting.get_parent() == placed.get_parent())
		var visitor: Unit = _townsperson(hero)
		if visitor and not _spawned.has(visitor):
			_spawned.append(visitor)
		CinematicDirector._skip_requested = true
		while result.is_empty():
			await get_tree().process_frame
		await get_tree().process_frame
		check("placed %d: the scene finished" % turn, result[0] == true)
		check("placed %d: the placed scene is still there, whole and out of sight" % turn,
			is_instance_valid(placed) and not placed.is_visible_in_tree()
			and (placed.get_node("Townsperson") as CutsceneRole).body != null
			and not is_instance_valid(acting))
		check("placed %d: the units are shown again" % turn,
			StandIn.body_of(hero).visible and visitor != null and StandIn.body_of(visitor).visible)
	placed.queue_free()
	free_spawned()
	await get_tree().process_frame


func _play_placed(placed: Cutscene, cast: SceneCast, result: Array) -> void:
	result.append(await CinematicDirector.play_placed(placed, cast))


func _play(scene: PackedScene, cast: SceneCast, result: Array) -> void:
	result.append(await CinematicDirector.play(scene, cast))


func _spawn(path: String, at: Vector3) -> Unit:
	var definition: UnitDefinition = load(path)
	var unit: Unit = definition.unit_scene.instantiate()
	unit.definition = definition
	_spawn_parent().add_child(unit)
	unit.global_position = at
	_spawned.append(unit)
	return unit


func _townsperson(not_this: Unit) -> Unit:
	var definition: UnitDefinition = load(TOWNSPERSON)
	for other in get_tree().get_nodes_in_group("units"):
		if other != not_this and (other as Unit).definition == definition:
			return other
	return null


func _flat(point: Vector3) -> Vector2:
	return Vector2(point.x, point.z)
