extends AiTestCase
## A jump flows from crouch to air to landing to standing, with no snap
## at any of the changes between them.
##
## Jump's wind-up is cut short on a timer and its airborne hold ends when
## the body touches down, so neither phase ends on a pose the next clip
## starts from. With a hard cut the knee turned about 90 degrees in a
## single frame at each change; UnitAnimator.phase_blend_time crossfades
## them. The clips' own fastest authored motion turns a joint about 35
## degrees between frames at 30 fps, and less the faster the test runs,
## so anything well past that can only be a cut.


const MAX_TURN_PER_FRAME := 50.0
## The bones a snap shows on. The fingers are left out: the clips curl them
## faster than any limb, and at this scale nobody sees a thumb.
const WATCHED := ["Hips", "Spine", "Chest", "UpperChest", "Neck", "Head",
	"LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot",
	"LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand",
	"RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand"]


func run() -> void:
	var jump: Ability = load("res://data/abilities/jump.tres")
	var unit: Unit = spawn_unit(&"player", 12, 12, 20, [melee(), jump], Vector3.ZERO)
	await get_tree().process_frame
	var player: AnimationPlayer = unit.animator().animation_player
	var skeleton: Skeleton3D = unit.find_children("*", "Skeleton3D", true, false)[0]
	var missing := WATCHED.filter(func(bone): return skeleton.find_bone(bone) < 0)
	check("SETUP: the skeleton has every watched bone", missing.is_empty(), str(missing))
	check("SETUP: the body has the jump clips", player.has_animation("Jump_Start")
		and player.has_animation("Jump") and player.has_animation("Jump_Land"))

	unit.set_base_stat(StatIds.FP, 20 - floori(unit.get_stat(StatIds.HT)))
	unit.set_pool(StatIds.FP, 20)
	# Let the idle pose land on the skeleton before measuring from it.
	for i in 5:
		await get_tree().process_frame
	var seen := {}
	var worst := 0.0
	var worst_at := ""
	var last := _pose(skeleton)
	unit.use_ability(jump, unit.global_position + unit.visual_forward() * 4.0)
	var until := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame
		var now := _pose(skeleton)
		var clip := String(player.current_animation)
		seen[clip] = true
		for b in now.size():
			var turn := rad_to_deg(now[b].angle_to(last[b]))
			if turn > worst:
				worst = turn
				worst_at = "%s, %.2f s into %s" % [WATCHED[b], player.current_animation_position, clip]
		last = now

	check("SETUP: it went through every phase and came to rest",
		seen.has("Jump_Start") and seen.has("Jump") and seen.has("Jump_Land")
			and player.current_animation == "Idle", "%s, now %s" % [seen.keys(), player.current_animation])
	check("no joint snaps between frames", worst <= MAX_TURN_PER_FRAME,
		"%.1f degrees at %s" % [worst, worst_at])
	free_spawned()


func _pose(skeleton: Skeleton3D) -> Array[Quaternion]:
	var out: Array[Quaternion] = []
	for bone in WATCHED:
		out.append(skeleton.get_bone_pose_rotation(skeleton.find_bone(bone)))
	return out
