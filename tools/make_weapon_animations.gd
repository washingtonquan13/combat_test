extends SceneTree

# Generates assets/weapon_animations.tres: one clip per kind of attack row,
# the defender's three answers to it, keyed onto the UAL mannequin's
# GeneralSkeleton.
#
#   godot --headless --path . -s res://tools/make_weapon_animations.gd
#
# Where a Quaternius pack has the movement, the clip is a copy of it (and of
# its _Rec recovery, joined on), so the motion is the artist's; where none
# does, the clip is built from key poses with tools/pose_builder.gd, whose
# header explains the bases and how a turn is given. Copied frames and built
# poses are both whole poses, so they blend into each other: the shots start
# from standing, take the aim from Pistol_Shoot, and go back to standing.
#
# Every attack clip carries Call Method keys on CharacterModel (see its
# release()/impact()): IMPACT on the frame a blow connects, RELEASE on the
# frame a shot or a throw leaves the hand, one per shot for rapid fire. The
# times were measured from the hand's speed and position in the source
# clips (the frame it passes the front or stops dead). Retune by editing the
# times or poses below and running this again; the clips are data the game
# reads. A clip that moves a key moves the moment the game waits on.
#
#   Swing         Sword_Regular_A + _Rec, right-to-left slash
#   Heavy_Swing   Sword_Regular_B + _Rec, the two-handed cut
#   Thrust        draw back, lunge with the arm straight out
#   Bash          Shield_OneShot, the off hand punched forward
#   Throw         OverhandThrow
#   Punch         Melee_Hook + _Rec
#   Claw          Zombie_Scratch
#   Bite          the head and chest lunge in, the jaw leading
#   Gore          head down, a charge, then a toss of the head
#   Pistol_Shot   Pistol_Shoot's aim, three shots with recoil
#   Rifle_Burst   a shouldered aim, ten shots
#   Crossbow_Shot the shouldered aim, one shot
#   Bow_Shot      the bow arm out, the string drawn to the cheek, loosed
#   Dodge         a sidestep to the left, leaning out of the line
#   Parry         Sword_Block
#   Block         the shield brought up across the chest, braced

const PoseBuilder := preload("res://tools/pose_builder.gd")

const OUT := "res://assets/weapon_animations.tres"
const UAL1 := "res://assets/unit_animations.tres"
const UAL2 := "res://assets/UAL2_Standard.glb"

# The character's forward, toward the target.
const FORWARD := Vector3(0, 0, 1)
const FINGERS := ["Index", "Middle", "Ring", "Little"]

# Moments, in seconds into each clip.
const SWING_IMPACT := 0.23
const HEAVY_IMPACT := 0.24
const THRUST_IMPACT := 0.36
const BASH_IMPACT := 0.12
const THROW_RELEASE := 0.36
const PUNCH_IMPACT := 0.27
const CLAW_IMPACT := 0.60
const BITE_IMPACT := 0.38
const GORE_IMPACT := 0.45

# The shots: when the aim is up, and how far apart the shots are.
const AIM_UP := 0.3
const PISTOL_SHOTS := 3
const PISTOL_GAP := 0.22
const RIFLE_SHOTS := 10
const RIFLE_GAP := 0.07
# How long the aim is held after the last shot, then the ease back down.
const AIM_HOLD := 0.3
const LOWER := 0.35
const BOW_RELEASE := 0.85

var _poses: PoseBuilder
var _ual1: AnimationLibrary
var _ual2: AnimationLibrary
var _standing: Dictionary


func _init() -> void:
	_poses = PoseBuilder.new()
	_ual1 = load(UAL1)
	_ual2 = load(UAL2)
	_standing = _poses.resolve(_poses.standing())
	var library := AnimationLibrary.new()

	library.add_animation("Swing", _keyed(_joined(["Sword_Regular_A", "Sword_Regular_A_Rec"]), {"impact": [SWING_IMPACT]}))
	library.add_animation("Heavy_Swing", _keyed(_joined(["Sword_Regular_B", "Sword_Regular_B_Rec"]), {"impact": [HEAVY_IMPACT]}))
	library.add_animation("Bash", _keyed(_joined(["Shield_OneShot"]), {"impact": [BASH_IMPACT]}))
	library.add_animation("Throw", _keyed(_joined(["OverhandThrow"]), {"release": [THROW_RELEASE]}))
	library.add_animation("Punch", _keyed(_joined(["Melee_Hook", "Melee_Hook_Rec"]), {"impact": [PUNCH_IMPACT]}))
	library.add_animation("Claw", _keyed(_joined(["Zombie_Scratch"]), {"impact": [CLAW_IMPACT]}))
	library.add_animation("Parry", _joined(["Sword_Block"]))

	library.add_animation("Thrust", _keyed(_poses.clip(0.95, false, _thrust), {"impact": [THRUST_IMPACT]}))
	library.add_animation("Bite", _keyed(_poses.clip(0.9, false, _bite), {"impact": [BITE_IMPACT]}))
	library.add_animation("Gore", _keyed(_poses.clip(1.05, false, _gore), {"impact": [GORE_IMPACT]}))
	library.add_animation("Pistol_Shot", _shots(PISTOL_SHOTS, PISTOL_GAP, _pistol_aim))
	library.add_animation("Rifle_Burst", _shots(RIFLE_SHOTS, RIFLE_GAP, _shoulder_aim))
	library.add_animation("Crossbow_Shot", _shots(1, 0.2, _shoulder_aim))
	library.add_animation("Bow_Shot", _keyed(_poses.clip(1.45, false, _bow), {"release": [BOW_RELEASE]}))
	library.add_animation("Dodge", _poses.clip(0.6, false, _dodge))
	library.add_animation("Block", _poses.clip(0.75, false, _block))

	var err := ResourceSaver.save(library, OUT)
	print("weapon animations: saved %s (%s)" % [OUT, error_string(err)])
	_poses.free_model()
	quit(0 if err == OK else 1)


# --- Copied clips ----------------------------------------------------------

func _source(clip: String) -> Animation:
	if _ual2.has_animation(clip):
		return _ual2.get_animation(clip)
	return _ual1.get_animation(clip)


# A source clip's frame at t as a whole pose: standing, with every bone the
# clip moves taken from it.
func _frame(anim: Animation, t: float) -> Dictionary:
	var pose := _standing.duplicate()
	for track in anim.get_track_count():
		var bone := String(anim.track_get_path(track)).get_slice(":", 1)
		match anim.track_get_type(track):
			Animation.TYPE_ROTATION_3D:
				if pose.has(bone):
					pose[bone] = anim.rotation_track_interpolate(track, t)
			Animation.TYPE_POSITION_3D:
				if bone == "Hips":
					pose["_hips"] = anim.position_track_interpolate(track, t)
	return pose


# The source clips played one after another as one clip.
func _joined(clips: Array) -> Animation:
	var anims: Array[Animation] = []
	var length := 0.0
	for clip: String in clips:
		anims.append(_source(clip))
		length += anims[-1].length
	return _poses.clip(length, false, func(t: float, _length: float) -> Dictionary:
		for anim in anims:
			if t <= anim.length or anim == anims[-1]:
				return _frame(anim, minf(t, anim.length))
			t -= anim.length
		return _standing)


# Adds a Call Method track on CharacterModel: method name -> key times.
static func _keyed(anim: Animation, moments: Dictionary) -> Animation:
	var track := anim.add_track(Animation.TYPE_METHOD)
	anim.track_set_path(track, NodePath(".."))
	for method: String in moments:
		for time: float in moments[method]:
			anim.track_insert_key(track, time, {"method": StringName(method), "args": []})
	return anim


# --- Shots -----------------------------------------------------------------

# Up from standing to the aim, `count` shots `gap` apart, each a kick back
# and a settle with a release key on the kick, the aim held, then down.
func _shots(count: int, gap: float, aim_at: Callable) -> Animation:
	var last_shot := AIM_UP + (count - 1) * gap
	var length := last_shot + AIM_HOLD + LOWER
	var releases: Array[float] = []
	for i in count:
		releases.append(AIM_UP + i * gap)
	var anim := _poses.clip(length, false, func(t: float, _length: float) -> Dictionary:
		if t <= AIM_UP:
			return _poses.keyed(t, [[0.0, _standing], [AIM_UP, aim_at.call(0.0)]])
		if t <= last_shot + AIM_HOLD:
			var since := fmod(t - AIM_UP, gap) if t < last_shot else t - last_shot
			return aim_at.call(since)
		return _poses.keyed(t, [[last_shot + AIM_HOLD, aim_at.call(AIM_HOLD)], [length, _standing]]))
	return _keyed(anim, {"release": releases})


# The kick of a shot, `since` seconds after it: back fast, settled by 0.15.
static func _kick(since: float) -> float:
	return exp(-since / 0.05) * (1.0 - exp(-since / 0.008))


# Pistol_Shoot's aim, the arm out at the target, kicked up by the recoil.
func _pistol_aim(since: float) -> Dictionary:
	var shoot := _source("Pistol_Shoot")
	return _frame(shoot, clampf(since, 0.0, 0.25) if since < 0.25 else 0.25)


# A long gun at the shoulder: the body bladed, left shoulder to the target,
# the head turned back over the sights; the right elbow out with the hand at
# the cheek on the grip, the left arm out under the barrel. The kick rocks
# the chest back and lifts both arms.
func _shoulder_aim(since: float) -> Dictionary:
	var kick := _kick(since) * 6.0
	var pose := {
		"_hips": Vector3(0, -0.02, 0),
		"Hips": Vector3(0, -30, 0),
		"Chest": Vector3(-kick * 0.5, 0, 0),
		"Neck": Vector3(6, 15, 0),
		"Head": Vector3(8, 15, 0),
		"LeftUpperLeg": Vector3(-10, 25, 5),
		"LeftLowerLeg": Vector3(10, 0, 0),
		"RightUpperLeg": Vector3(8, 25, -5),
		"RightLowerLeg": Vector3(8, 0, 0),
		"RightUpperArm": Vector3(-kick, 30, -40),
		"RightLowerArm": Vector3(-120, 0, 0),
		"LeftUpperArm": Vector3(-70 - kick, 25, 6),
		"LeftLowerArm": Vector3(-25, 0, 0),
	}
	_fingers(pose, "Right", 0.8)
	_fingers(pose, "Left", 0.6)
	# The barrel on the target, lifted by the kick.
	_poses.hold(pose, "Right", FORWARD + Vector3(0, kick * 0.03, 0), Vector3.UP)
	return pose


# --- Built clips -----------------------------------------------------------

func _fingers(pose: Dictionary, side: String, curl: float) -> void:
	var roll := curl if side == "Right" else -curl
	for finger: String in FINGERS:
		PoseBuilder.add(pose, "%s%sProximal" % [side, finger], Vector3(0, 0, 55 * roll))
		PoseBuilder.add(pose, "%s%sIntermediate" % [side, finger], Vector3(0, 0, 75 * roll))
		PoseBuilder.add(pose, "%s%sDistal" % [side, finger], Vector3(0, 0, 45 * roll))


# Weight on both feet, left a little ahead, the right fist closed on a grip.
func _guard() -> Dictionary:
	var pose := {
		"_hips": Vector3(0, -0.03, 0),
		"Hips": Vector3(0, -10, 0),
		"Spine": Vector3(4, 4, 0),
		"Chest": Vector3(2, 4, 0),
		"Head": Vector3(-4, 2, 0),
		"LeftUpperLeg": Vector3(-14, 6, 5),
		"LeftLowerLeg": Vector3(12, 0, 0),
		"RightUpperLeg": Vector3(8, 6, -5),
		"RightLowerLeg": Vector3(10, 0, 0),
		"LeftUpperArm": Vector3(-20, 0, -10),
		"LeftLowerArm": Vector3(-50, 0, 0),
		"RightUpperArm": Vector3(-10, 0, -8),
		"RightLowerArm": Vector3(-70, 0, 0),
		"RightHand": Vector3(-20, 0, 0),
	}
	_fingers(pose, "Right", 0.9)
	_fingers(pose, "Left", 0.5)
	return pose


func _thrust(t: float, length: float) -> Dictionary:
	# Drawn back: the hand at the hip, point forward, the body coiled.
	var drawn := _guard()
	drawn["Hips"] = Vector3(0, -22, 0)
	drawn["Chest"] = Vector3(0, -6, 0)
	drawn["RightUpperArm"] = Vector3(25, 0, -12)
	drawn["RightLowerArm"] = Vector3(-95, 0, 0)
	drawn["RightHand"] = Vector3(-10, 0, 0)
	# The lunge: a step in on the left foot, the arm straight out at the
	# target, shoulder high, the blade level with it.
	var lunge := _guard()
	lunge["_hips"] = Vector3(0, -0.09, 0.22)
	lunge["Hips"] = Vector3(6, 18, 0)
	lunge["Spine"] = Vector3(10, 6, 0)
	lunge["Chest"] = Vector3(4, 8, 0)
	lunge["LeftUpperLeg"] = Vector3(-50, 0, 5)
	lunge["LeftLowerLeg"] = Vector3(45, 0, 0)
	lunge["RightUpperLeg"] = Vector3(25, 0, -5)
	lunge["RightLowerLeg"] = Vector3(15, 0, 0)
	lunge["RightUpperArm"] = Vector3(-84, 10, -4)
	lunge["RightLowerArm"] = Vector3(-4, 0, 0)
	lunge["LeftUpperArm"] = Vector3(20, 0, -20)
	lunge["LeftLowerArm"] = Vector3(-20, 0, 0)
	# The blade straight out at the target, edge down.
	_poses.hold(lunge, "Right", Vector3.DOWN, FORWARD)
	return _poses.keyed(t, [
		[0.0, _standing],
		[0.2, drawn],
		[THRUST_IMPACT, lunge],
		[0.52, lunge],
		[length, _standing],
	])


func _bite(t: float, length: float) -> Dictionary:
	# Reared back, then the head driven in low, the jaw first.
	var reared := _guard()
	reared["Spine"] = Vector3(-8, 0, 0)
	reared["Chest"] = Vector3(-8, 0, 0)
	reared["Neck"] = Vector3(-10, 0, 0)
	reared["Head"] = Vector3(-15, 0, 0)
	reared["RightLowerArm"] = Vector3(-60, 0, 0)
	var lunge := _guard()
	lunge["_hips"] = Vector3(0, -0.08, 0.2)
	lunge["Spine"] = Vector3(22, 0, 0)
	lunge["Chest"] = Vector3(14, 0, 0)
	lunge["Neck"] = Vector3(12, 0, 0)
	lunge["Head"] = Vector3(-18, 0, 0)
	lunge["LeftUpperLeg"] = Vector3(-35, 0, 5)
	lunge["LeftLowerLeg"] = Vector3(30, 0, 0)
	lunge["RightUpperLeg"] = Vector3(20, 0, -5)
	lunge["LeftUpperArm"] = Vector3(-40, 0, -20)
	lunge["RightUpperArm"] = Vector3(-40, 0, 20)
	return _poses.keyed(t, [
		[0.0, _standing],
		[0.22, reared],
		[BITE_IMPACT, lunge],
		[0.5, lunge],
		[length, _standing],
	])


func _gore(t: float, length: float) -> Dictionary:
	# The head dropped, horns forward, a short charge; at the contact the
	# head tosses up through the target.
	var lowered := _guard()
	lowered["Spine"] = Vector3(18, 0, 0)
	lowered["Chest"] = Vector3(10, 0, 0)
	lowered["Neck"] = Vector3(15, 0, 0)
	lowered["Head"] = Vector3(30, 0, 0)
	var charge := lowered.duplicate()
	charge["_hips"] = Vector3(0, -0.08, 0.3)
	charge["Spine"] = Vector3(28, 0, 0)
	charge["LeftUpperLeg"] = Vector3(-40, 0, 5)
	charge["LeftLowerLeg"] = Vector3(35, 0, 0)
	charge["RightUpperLeg"] = Vector3(25, 0, -5)
	charge["LeftUpperArm"] = Vector3(25, 0, -15)
	charge["RightUpperArm"] = Vector3(25, 0, 15)
	var toss := charge.duplicate()
	toss["_hips"] = Vector3(0, -0.04, 0.3)
	toss["Spine"] = Vector3(4, 0, 0)
	toss["Chest"] = Vector3(-6, 0, 0)
	toss["Neck"] = Vector3(-10, 0, 0)
	toss["Head"] = Vector3(-25, 0, 0)
	return _poses.keyed(t, [
		[0.0, _standing],
		[0.25, lowered],
		[GORE_IMPACT, charge],
		[0.62, toss],
		[length, _standing],
	])


func _bow(t: float, length: float) -> Dictionary:
	# Bladed to the target, left side forward, the head turned to it: the
	# bow arm straight out at shoulder height, the right hand on the string
	# in front of the chest.
	var nocked := {
		"_hips": Vector3(0, -0.02, 0),
		"Hips": Vector3(0, -70, 0),
		"Neck": Vector3(0, 30, 0),
		"Head": Vector3(0, 38, 0),
		"LeftUpperLeg": Vector3(-6, 70, 10),
		"RightUpperLeg": Vector3(4, 70, -10),
		"LeftUpperArm": Vector3(0, -20, 72),
		"LeftLowerArm": Vector3(0, 0, 0),
		"RightUpperArm": Vector3(0, 50, -60),
		"RightLowerArm": Vector3(-100, 0, 0),
	}
	_fingers(nocked, "Left", 0.9)
	_fingers(nocked, "Right", 0.4)
	# The bow upright, its face to the target.
	_poses.hold(nocked, "Left", FORWARD, Vector3.UP)
	# Drawn: the right elbow back level with the shoulder, the string hand
	# folded in to the cheek.
	var drawn := nocked.duplicate()
	drawn["RightUpperArm"] = Vector3(0, 0, -80)
	drawn["RightLowerArm"] = Vector3(-145, 0, 0)
	# Loosed: the string hand flies back past the ear, the fingers open.
	var loosed := drawn.duplicate()
	loosed["RightUpperArm"] = Vector3(0, -15, -82)
	loosed["RightLowerArm"] = Vector3(-110, 0, 0)
	_fingers(loosed, "Right", -0.4)
	return _poses.keyed(t, [
		[0.0, _standing],
		[0.3, nocked],
		[0.75, drawn],
		[BOW_RELEASE, drawn],
		[0.95, loosed],
		[1.1, loosed],
		[length, _standing],
	])


func _dodge(t: float, length: float) -> Dictionary:
	# A step to the left, the body leaning out of the line of the blow.
	var out := {
		"_hips": Vector3(0.3, -0.06, -0.05),
		"Hips": Vector3(0, 0, 12),
		"Spine": Vector3(-4, 0, 10),
		"Chest": Vector3(-4, 0, 8),
		"Head": Vector3(0, 0, -10),
		"LeftUpperLeg": Vector3(0, 0, 25),
		"LeftLowerLeg": Vector3(20, 0, 0),
		"RightUpperLeg": Vector3(-10, 0, 5),
		"RightLowerLeg": Vector3(15, 0, 0),
		"LeftUpperArm": Vector3(-20, 0, -20),
		"RightUpperArm": Vector3(-30, 0, 35),
		"RightLowerArm": Vector3(-60, 0, 0),
	}
	return _poses.keyed(t, [
		[0.0, _standing],
		[0.18, out],
		[0.32, out],
		[length, _standing],
	])


func _block(t: float, length: float) -> Dictionary:
	# The off hand's shield up across the chest, the body set behind it.
	var braced := _guard()
	braced["_hips"] = Vector3(0, -0.06, -0.04)
	braced["Spine"] = Vector3(8, 0, 0)
	braced["Chest"] = Vector3(4, 0, 0)
	braced["Head"] = Vector3(8, 0, 0)
	braced["LeftUpperArm"] = Vector3(-55, -25, -10)
	braced["LeftLowerArm"] = Vector3(-15, 0, 85)
	braced["LeftHand"] = Vector3(0, 0, 0)
	return _poses.keyed(t, [
		[0.0, _standing],
		[0.14, braced],
		[0.4, braced],
		[length, _standing],
	])
