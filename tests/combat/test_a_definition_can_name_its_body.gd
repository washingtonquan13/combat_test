extends AiTestCase
## A definition names a body, and the unit wears it instead of the one its
## scene was authored with.
##
## All 32 demons shared a single hardcoded body: an imported placeholder
## .glb instanced directly into unit.tscn, with the outline mesh and the
## animator reaching across into it by NodePath —
##
##   OutlineMesh.skeleton          = "../CharacterModel/Armature/GeneralSkeleton"
##   UnitAnimator.animation_player = "../CharacterModel/AnimationPlayer"
##
## — so the body could not be swapped without those paths dangling. The
## outline was skinned to that one skeleton while living outside it.
##
## CharacterModel gathers the body and its parts into one authored scene,
## and Unit._enter_tree() adopts whichever one the definition names,
## BEFORE any child of the unit scene has readied. That timing is the
## whole mechanism: nothing has bound to the outgoing AnimationPlayer yet,
## so there is nothing to unwire.
##
## The last check matters as much as the rest. A definition that names no
## body must keep the one it was authored with — otherwise this is not an
## opt-in feature, it is a migration, and every existing demon is in it.

const WHITEBOX := "res://scenes/character_models/whitebox_model.tscn"

var _units: Array[Unit] = []


func run() -> void:
	await _a_named_body_replaces_the_authored_one()
	await _a_body_with_no_clips_can_still_act()
	await _a_real_demon_wears_the_placeholder()
	_a_unit_with_no_definition_still_works()
	_cleanup()
	free_spawned()


func _a_named_body_replaces_the_authored_one() -> void:
	var unit: Unit = _spawn_wearing(WHITEBOX)
	await get_tree().process_frame

	var body: Node = unit.get_node_or_null("CharacterModel")
	check("the unit wears the body its definition named",
		body is CharacterModel,
		"CharacterModel is %s" % ("missing" if body == null else body.get_class()))
	if not (body is CharacterModel):
		return

	check("and the authored body is gone, not merely hidden",
		unit.find_child("GeneralSkeleton", true, false) == null,
		"the placeholder skeleton is still in the tree — two bodies")

	# The outline mesh was skinned to that skeleton. Left behind, it would
	# be one creature's silhouette welded to bones that no longer exist.
	check("and the outline skinned to it went with it",
		not is_instance_valid(unit.outline_mesh) or unit.outline_mesh.get_parent() == body,
		"outline_mesh survived its skeleton")

	check("and the selection ring now belongs to the new body",
		is_instance_valid(unit.highlight_mesh) and unit.highlight_mesh.get_parent() == body,
		"highlight_mesh is not the one this body declares")

	var animator: Node = unit.get_node_or_null("UnitAnimator")
	check("and the animator drives the new body's player",
		animator != null and is_instance_valid(animator.animation_player)
			and animator.animation_player.get_parent() == body,
		"the animator is still pointed at the old body's AnimationPlayer")


## The whitebox declares an AnimationPlayer with nothing in it and no clip
## names at all — which is the prototype case, and only works because a
## phase that cannot start is treated as already finished.
func _a_body_with_no_clips_can_still_act() -> void:
	var unit: Unit = _spawn_wearing(WHITEBOX)
	await get_tree().process_frame

	var animator: Node = unit.get_node_or_null("UnitAnimator")
	if animator == null or not is_instance_valid(animator.animation_player):
		check("SETUP: the whitebox body has a player to check", false)
		return

	check("the whitebox body declares no clips",
		animator.animation_player.get_animation_list().size() == 0,
		"%d clip(s)" % animator.animation_player.get_animation_list().size())
	check("and no clip names either, so nothing warns about missing art",
		animator.idle_animation == "" and animator.death_animation == "",
		"idle '%s', death '%s'" % [animator.idle_animation, animator.death_animation])

	unit.use_ability(unit.abilities[0], unit)
	await get_tree().process_frame
	check("and it can use an ability without being stranded",
		animator._active_sequence == null,
		"stuck on phase %d" % animator._active_phase_index)


## Real authored content, not a synthetic definition — every one of the 32
## UnitDefinitions now names the placeholder body, so this is the path the
## whole game takes.
##
## It is also the migration guard. unit.tscn used to carry 43 baked
## Animation sub-resources — 17,600 of its 17,877 lines — in a library
## overriding the one the .glb imports. Those moved to
## assets/unit_animations.tres and the body to placeholder_model.tscn, and
## the entire point was that nothing about playback should change.
##
## A silent failure here looks like a demon that spawns, walks, fights and
## dies perfectly while playing nothing at all.
func _a_real_demon_wears_the_placeholder() -> void:
	var demon: Unit = spawn_demon("hobgoblin", Vector3.ZERO)
	await get_tree().process_frame

	var body: Node = demon.get_node_or_null("CharacterModel")
	check("a demon from data/ wears the body its definition names",
		body is CharacterModel,
		"CharacterModel is %s" % ("missing" if body == null else body.get_class()))

	var animator: Node = demon.get_node_or_null("UnitAnimator")
	if animator == null or not is_instance_valid(animator.animation_player):
		check("SETUP: it has an animator bound to a player", false)
		return

	var player: AnimationPlayer = animator.animation_player
	check("and the extracted library still holds all 43 clips",
		player.get_animation_list().size() >= 43,
		"%d clip(s) — the library did not survive extraction" % player.get_animation_list().size())

	# By NAME, because names are what the animator asks for. A library that
	# loaded but lost its keys would still pass a count.
	for named in ["Idle", "Jog_Fwd", "Hit_Chest", "Death01"]:
		check("and '%s' is still there to play" % named, player.has_animation(named))

	check("and the body declares those names to the animator",
		animator.idle_animation == "Idle" and animator.walk_animation == "Jog_Fwd"
			and animator.hit_animation == "Hit_Chest" and animator.death_animation == "Death01",
		"idle '%s', walk '%s', hit '%s', death '%s'" % [
			animator.idle_animation, animator.walk_animation,
			animator.hit_animation, animator.death_animation])


## unit.tscn carries no body of its own any more, so a unit built without a
## definition has none. That is a legitimate state rather than a broken
## one — it is the whitebox case by another route — and it must degrade
## rather than crash.
func _a_unit_with_no_definition_still_works() -> void:
	var unit: Unit = load("res://unit.tscn").instantiate()
	_root.add_child(unit)
	_units.append(unit)

	check("a unit with no definition simply has no body",
		unit.get_node_or_null("CharacterModel") == null)
	check("and still answers for its anchors, from the proportions",
		is_equal_approx(unit.anchor(CharacterModel.Anchor.EYE).y - unit.global_position.y, 1.5),
		"eye at %.3f" % (unit.anchor(CharacterModel.Anchor.EYE).y - unit.global_position.y))
	check("and still collides, because the shape is the Unit's own",
		is_instance_valid(unit.get_node_or_null("CollisionShape3D")))


func _spawn_wearing(model_path: String) -> Unit:
	var definition := UnitDefinition.new()
	definition.model_scene = load(model_path)
	definition.max_hp = 20
	definition.faction = &"player"

	var unit: Unit = load("res://unit.tscn").instantiate()
	# BEFORE add_child, because _enter_tree is what reads it — the same
	# order debug_spawn_panel and PartyManager already use.
	unit.definition = definition
	_root.add_child(unit)
	var abilities: Array[Ability] = [melee()]
	unit.abilities = abilities
	unit.reset_turn_actions()
	_units.append(unit)
	return unit


func _cleanup() -> void:
	for unit in _units:
		if is_instance_valid(unit):
			if unit.is_in_group("units"):
				unit.remove_from_group("units")
			if unit.get_parent():
				unit.get_parent().remove_child(unit)
			unit.queue_free()
	_units.clear()


## The migration guard.
##
## unit.tscn used to carry 43 baked Animation sub-resources — 17,600 of its
## 17,877 lines — in a local library overriding the one the .glb imports.
## Those moved to assets/unit_animations.tres and the body moved to
## scenes/character_models/placeholder_model.tscn, and the whole point of
## doing it that way was that NOTHING about playback should change.
##
## A silent failure here looks like a unit that spawns, walks, fights and
## dies perfectly while playing no animation at all — which every other
## check in this file would happily pass.
func _the_default_body_kept_its_clips() -> void:
	var unit: Unit = load("res://unit.tscn").instantiate()
	_root.add_child(unit)
	_units.append(unit)

	var animator: Node = unit.get_node_or_null("UnitAnimator")
	if animator == null or not is_instance_valid(animator.animation_player):
		check("SETUP: the default body still has an animator and a player", false)
		return

	var player: AnimationPlayer = animator.animation_player
	check("the extracted library still holds all 43 clips",
		player.get_animation_list().size() >= 43,
		"%d clip(s) — the library did not survive extraction" % player.get_animation_list().size())

	# By NAME, because the names are what the animator asks for. A library
	# that loaded but lost its keys would still pass a count.
	for named in ["Idle", "Jog_Fwd", "Hit_Chest", "Death01"]:
		check("and '%s' is still there to play" % named,
			player.has_animation(named))

	check("and the body declares those names to the animator",
		animator.idle_animation == "Idle" and animator.walk_animation == "Jog_Fwd"
			and animator.hit_animation == "Hit_Chest" and animator.death_animation == "Death01",
		"idle '%s', walk '%s', hit '%s', death '%s'" % [
			animator.idle_animation, animator.walk_animation,
			animator.hit_animation, animator.death_animation])
