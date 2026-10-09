extends AiTestCase
## Fireball's stance chains: arming raises the flame, it is held, and it is
## either put away or launched, each clip flowing out of the last.
##
## Three things make that work, and each has a check here. The clips meet
## on shared poses (built that way by tools/make_fireball_animations.gd).
## Disarming plays the exit only while the stance is still on screen, so
## the auto-disarm that follows a cast cannot cut the cast. And only the
## unit that armed reacts: ability_armed is one global signal, and before
## AbilityManager.armed_unit every idle unit out of combat raised its hand.


const MAX_JOIN_DEGREES := 1.0


## The arming sound, the cast's delay and the projectile all play into the
## world's spawn parent, so without one they have nowhere to go.
func wants_world() -> bool:
	return true


func run() -> void:
	_the_clips_meet_on_shared_poses()
	await _arm_hold_and_put_away()
	await _launched_from_the_stance()
	AbilityManager.disarm()
	SelectionManager.deselect_all()
	free_spawned()


func _fireball() -> Ability:
	return load("res://data/abilities/explosive_fireball.tres")


func _the_clips_meet_on_shared_poses() -> void:
	var unit: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3.ZERO)
	var player: AnimationPlayer = unit.animator().animation_player
	for clip in ["Fireball/Arm", "Fireball/Hold", "Fireball/Disarm", "Fireball/Cast"]:
		check("SETUP: the body has %s" % clip, player.has_animation(clip))
	if not player.has_animation("Fireball/Cast"):
		return
	var arm := player.get_animation("Fireball/Arm")
	var hold := player.get_animation("Fireball/Hold")
	var disarm := player.get_animation("Fireball/Disarm")
	var cast := player.get_animation("Fireball/Cast")
	var idle := player.get_animation("Idle")
	_check_join("Arm ends where Hold begins", arm, arm.length, hold, 0.0)
	_check_join("Hold loops back onto its own start", hold, hold.length, hold, 0.0)
	_check_join("Disarm starts from the hold", hold, 0.0, disarm, 0.0)
	_check_join("Cast starts from the hold", hold, 0.0, cast, 0.0)
	_check_join("Disarm ends on Idle's first frame", disarm, disarm.length, idle, 0.0)
	_check_join("Cast ends on Idle's first frame", cast, cast.length, idle, 0.0)
	_check_join("Arm starts from Idle's first frame", idle, 0.0, arm, 0.0)


## The largest turn, over every bone, between two clips at two times.
func _check_join(label: String, a: Animation, at: float, b: Animation, bt: float) -> void:
	var worst := 0.0
	var worst_bone := ""
	for track in a.get_track_count():
		if a.track_get_type(track) != Animation.TYPE_ROTATION_3D:
			continue
		var path := a.track_get_path(track)
		var other := b.find_track(path, Animation.TYPE_ROTATION_3D)
		if other < 0:
			continue
		var qa: Quaternion = a.rotation_track_interpolate(track, at)
		var qb: Quaternion = b.rotation_track_interpolate(other, bt)
		var degrees := rad_to_deg(qa.angle_to(qb))
		if degrees > worst:
			worst = degrees
			worst_bone = str(path)
	check(label, worst <= MAX_JOIN_DEGREES, "%.1f degrees at %s" % [worst, worst_bone])


func _arm_hold_and_put_away() -> void:
	var caster: Unit = spawn_unit(&"player", 12, 12, 20, [melee(), _fireball()], Vector3.ZERO)
	var bystander: Unit = spawn_unit(&"player", 12, 12, 20, [melee(), _fireball()], Vector3(3, 0, 0))
	await get_tree().process_frame
	var player: AnimationPlayer = caster.animator().animation_player
	var their_player: AnimationPlayer = bystander.animator().animation_player

	SelectionManager.select(caster)
	check("SETUP: the caster is the commanded unit", PlayerInteractionState.get_active_unit() == caster)
	AbilityManager.arm(_fireball())
	check("arming raises the flame", player.current_animation == "Fireball/Arm", player.current_animation)
	check("and a unit that did not arm stays as it was", their_player.current_animation == "Idle",
		their_player.current_animation)

	await get_tree().create_timer(0.9).timeout
	check("then it holds the flame", player.current_animation == "Fireball/Hold", player.current_animation)
	var flame := caster.get_node_or_null("FireballHold") as Node3D
	check("a fireball burns in the caster's hand", flame != null)
	check("and none in the hand of a unit that did not arm", bystander.get_node_or_null("FireballHold") == null)
	if flame:
		var gap := flame.global_position.distance_to(caster.anchor(CharacterModel.Anchor.HAND))
		check("the fireball sits on the hand", gap < 0.01, "%.3f m off" % gap)

	AbilityManager.disarm()
	check("disarming snuffs it and lowers the hand", player.current_animation == "Fireball/Disarm",
		player.current_animation)
	await get_tree().process_frame
	check("the fireball dies out rather than vanishing", is_instance_valid(flame))
	await get_tree().create_timer(0.7).timeout
	check("and then it stands at rest", player.current_animation == "Idle", player.current_animation)
	await get_tree().create_timer(0.4).timeout
	check("and the snuffed fireball is gone", not is_instance_valid(flame))

	# Disarming with the stance already gone leaves alone what replaced it.
	AbilityManager.arm(_fireball())
	player.play("Hit_Chest")
	AbilityManager.disarm()
	check("a disarm after something else took over does not interrupt it",
		player.current_animation == "Hit_Chest", player.current_animation)
	free_spawned()


func _launched_from_the_stance() -> void:
	var caster: Unit = spawn_unit(&"player", 12, 12, 20, [melee(), _fireball()], Vector3.ZERO)
	await get_tree().process_frame
	var player: AnimationPlayer = caster.animator().animation_player
	SelectionManager.select(caster)
	AbilityManager.arm(_fireball())
	await get_tree().create_timer(0.9).timeout
	check("SETUP: holding the flame", player.current_animation == "Fireball/Hold", player.current_animation)

	var chest := caster.anchor(CharacterModel.Anchor.CHEST)
	var held := caster.anchor(CharacterModel.Anchor.HAND)
	check("held, the hand is above the shoulder", held.y > 1.45, "hand y=%.2f" % held.y)

	caster.ability_use_started.emit(caster, caster.global_position + caster.visual_forward() * 6.0, _fireball())
	check("casting launches from the stance", player.current_animation == "Fireball/Cast",
		player.current_animation)
	# The auto-disarm after a use arrives mid-cast.
	AbilityManager.disarm()
	check("the disarm that follows the cast does not cut it", player.current_animation == "Fireball/Cast",
		player.current_animation)

	await get_tree().create_timer(0.32).timeout
	var released := caster.anchor(CharacterModel.Anchor.HAND)
	var reach := (released - chest).dot(caster.visual_forward())
	check("at release the hand is out in front, where the fireball leaves from", reach > 0.4,
		"%.2f m ahead of the chest" % reach)

	await get_tree().create_timer(1.1).timeout
	check("after the cast it stands at rest", player.current_animation == "Idle", player.current_animation)
	free_spawned()
