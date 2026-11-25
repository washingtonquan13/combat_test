extends Node
## Standalone recorded walkthrough — NOT a test, NOT part of tests/run.sh.
## Boots the real game, puts the hero in the Pilgrim's Robe (weapons off),
## and walks them out and back past a close side camera, so the skirt's
## spring bones (CCWear) show swinging and pushed off the legs. Prints how
## far the cloth bones swung from rest.
##
##   tools/render_movie.sh res://tools/robe_demo.tscn recordings/robe/robe_walk.avi

const MainRootScene: PackedScene = preload("res://MainRoot.tscn")
const Robe: GearItem = preload("res://data/items/pilgrim_robe.tres")

var _hero: Unit
var _cam: Camera3D
var _swing := 0.0


func _ready() -> void:
	add_child(MainRootScene.instantiate())
	_run.call_deferred()


func _run() -> void:
	await _wait(1.0)
	get_tree().get_first_node_in_group("main_menu")._on_start_pressed()
	await _wait(1.0)
	var creation: Node = get_tree().get_first_node_in_group("character_creation")
	creation._on_auto_fill_pressed()
	await _wait(0.5)
	creation._on_confirm_pressed()
	await WorldManager.world_focused
	_hero = PartyManager.leader
	for slot in [EquipSlot.Slot.SET_1_MAIN_HAND, EquipSlot.Slot.SET_1_OFF_HAND,
			EquipSlot.Slot.SET_2_MAIN_HAND, EquipSlot.Slot.SET_2_OFF_HAND]:
		_hero.unequip_item(slot)
	_hero.equip_item(EquipSlot.Slot.CHEST_ARMOR, ItemInstance.new(Robe))
	await _wait(0.5)
	var sim := _hero.find_children("ClothSprings", "SpringBoneSimulator3D", true, false)
	print("ROBE simulator ", sim.size(), " chains ", sim[0].get_setting_count() if sim else 0)
	# The rest of the party out of shot.
	var i := 0
	for member: Unit in PartyManager.members:
		if member != _hero:
			member.global_position = _hero.global_position + Vector3(8.0 + i * 1.5, 0, 8.0)
			i += 1
	var start := _hero.global_position
	var ahead := -_hero.global_transform.basis.z.normalized()
	_cam = Camera3D.new()
	_cam.fov = 40.0
	# No grass or ground plants (they hide the hem), nor the x-ray depth quad.
	_cam.cull_mask &= ~(1 << (XRaySilhouettes.SEE_THROUGH_LAYER - 1)) & ~(1 << (XRaySilhouettes.CAPTURE_LAYER - 1))
	WorldManager.focused_viewport().add_child(_cam)
	_cam.make_current()
	# The grass off outright: culled from the camera it still shadows the hem.
	for g: GeometryInstance3D in get_tree().root.find_children("*", "GeometryInstance3D", true, false):
		if g.get_layer_mask_value(XRaySilhouettes.SEE_THROUGH_LAYER):
			g.visible = false
	await _wait(1.5)
	_hero.move_to(start + ahead * 6.0)
	await _wait(5.0)
	_hero.move_to(start)
	await _wait(5.0)
	print("ROBE max cloth swing from rest: %.1f deg" % rad_to_deg(_swing))
	get_tree().quit()


func _process(_delta: float) -> void:
	if _cam == null or not is_instance_valid(_hero):
		return
	var at := _hero.global_position + Vector3.UP * 0.9
	_cam.global_position = at + _hero_side() * 3.2 + Vector3.UP * 0.3
	_cam.look_at(at)
	var skel := _hero.find_children("*", "Skeleton3D", true, false)
	for s: Skeleton3D in skel:
		for b in s.get_bone_count():
			if s.get_bone_name(b).begins_with("Spring_"):
				var d := s.get_bone_pose_rotation(b).angle_to(s.get_bone_rest(b).basis.get_rotation_quaternion())
				_swing = maxf(_swing, d)


## A fixed side for the camera: the world's +X, so it does not orbit as the hero turns.
func _hero_side() -> Vector3:
	return Vector3(1, 0, 0.35).normalized()


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
