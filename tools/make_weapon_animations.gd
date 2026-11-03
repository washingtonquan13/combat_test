extends SceneTree

# Generates assets/weapon_animations.tres: one clip per kind of attack row,
# keyed onto the UAL mannequin's GeneralSkeleton.
#
#   godot --headless --path . -s res://tools/make_weapon_animations.gd
#
# Where a Quaternius pack has the movement, the clip is a copy of it (and of
# its _Rec recovery, joined on), so the motion is the artist's; where none
# does, the clip is built from key poses with tools/pose_builder.gd, whose
# header explains the bases and how a turn is given. Copied frames and built
# poses are both whole poses, so they blend into each other: a shot starts
# from its weapon's stance, takes the aim, and goes back to the stance.
#
# Every attack clip carries Call Method keys on CharacterModel (see its
# release()/impact()): IMPACT on the frame a blow connects, RELEASE on the
# frame a shot or a throw leaves the hand, one per shot for rapid fire. The
# times were measured from the hand's speed and position in the source
# clips (the frame it passes the front or stops dead). Retune by editing the
# times or poses below and running this again; the clips are data the game
# reads. A clip that moves a key moves the moment the game waits on.
#
#   Swing         Sword_Attack, eased from and back to Kevin Iglesias' guard
#   Heavy_Swing   Attack2H01 (Kevin Iglesias), the two-handed cut, refitted
#   Heavy_Thrust  CombatIdle2H01 (Kevin Iglesias) driven into a two-handed thrust
#   Thrust        Attack1H01_R (Kevin Iglesias), a lunge, the arm straight out
#   Bash          Shield_OneShot, the off hand punched forward
#   Throw         OverhandThrow
#   Punch         Melee_Hook + _Rec
#   Claw          Zombie_Scratch
#   Bite          the head and chest lunge in, the jaw leading
#   Gore          head down, a charge, then a toss of the head
#   Pistol_Shot   one hand, turned from the idle into a bladed stance, arm raised level, three shots
#   Rifle_Burst   raised to the shoulder from the stance, ten shots
#   Crossbow_Shot raised to the shoulder, one shot
#   Bow_Shot      BowShot01 Load + Release (Kevin Iglesias), raised from the stance, refitted
#
# The stances are the looping idles a unit stands in with a weapon drawn
# (WeaponData.stance_animation), and the reloads what Reload plays
# (WeaponData.reload_animation).
#
#   Stance_Sword       CombatIdle1H01 (Kevin Iglesias), the low one-handed guard
#   Stance_Shield      Idle_Shield
#   Stance_Pistol      the Idle, square, the gun hanging at the right thigh
#   Stance_Greatsword  CombatIdle2H01 (Kevin Iglesias), refitted to our sword
#   Stance_Longgun     AssaultRifle_Aim01 (Kevin Iglesias), refitted to our gun
#   Stance_Crossbow    the same, the left hand on the crossbow's forestock
#   Stance_Bow         BowIdle02 (Kevin Iglesias), refitted to our bow
#   Reload_Pistol      Pistol_Reload, two handed, refitted to our gun
#   Reload_Rifle       AssaultRifle_Reload01 (Kevin Iglesias), refitted
#   Reload_Crossbow    AssaultRifle_Reload01 (Kevin Iglesias), the string hauled back first
#
# And one that isn't a weapon's: Jump_Start, the jump's wind-up and spring.

const PoseBuilder := preload("res://tools/pose_builder.gd")
# The long guns' stance and aim and the rifle's reload, from the Kevin
# Iglesias soldier clips.
const KevinRifle := preload("res://tools/kevin_rifle.gd")
# The greatsword's stance and cut, from the Kevin Iglesias melee clips.
const KevinGreatsword := preload("res://tools/kevin_greatsword.gd")
# The one-handed sword's stance, cut and thrust, from the same pack.
const KevinSword := preload("res://tools/kevin_sword.gd")
# The longbow's stance and shot, from the Kevin Iglesias archer clips.
const KevinBow := preload("res://tools/kevin_bow.gd")
# The pistol's stance, shot and reload, from the Quaternius clips.
const QuaterniusPistol := preload("res://tools/quaternius_pistol.gd")

const OUT := "res://assets/weapon_animations.tres"
const UAL1 := "res://assets/unit_animations.tres"
const UAL2 := "res://assets/UAL2_Standard.glb"

# The character's forward, toward the target.
const FORWARD := Vector3(0, 0, 1)
const FINGERS := ["Index", "Middle", "Ring", "Little"]

# Moments, in seconds into each clip.
const HEAVY_IMPACT := 0.57
const BASH_IMPACT := 0.12
const THROW_RELEASE := 0.36
const PUNCH_IMPACT := 0.27
const CLAW_IMPACT := 0.60
const BITE_IMPACT := 0.38
const GORE_IMPACT := 0.45

# The shots: when the aim is up, the beat held on target before the first
# shot, and how far apart the shots are.
const AIM_UP := 0.45
const SETTLE := 0.25
const PISTOL_SHOTS := 3
const PISTOL_GAP := 0.4
const RIFLE_SHOTS := 10
const RIFLE_GAP := 0.07
# How long the aim is held after the last shot, then the ease back down.
const AIM_HOLD := 0.5
const LOWER := 0.45
# A one-handed raise: the body turns first, through the lift (the arm out
# low) at LIFT_AT, and the arm comes up after it by ARM_LAG.
const LIFT_AT := 0.22
const ARM_LAG := 0.1
const ARM := ["RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand"]
# The jump. Quaternius' Jump_Start begins at the bottom of its crouch and is
# up within a few frames, so the way down is Jump_Land's way up run
# backwards (its frame at CROUCH is Jump_Start's first) from where it has
# stood at RISEN, over SINK seconds. Then Jump_Start to SPRUNG, the body in
# the air, the feet leaving the ground at LIFT_OFF.
const CROUCH := 0.1
const RISEN := 0.8
const SINK := 0.45
const SPRUNG := 0.3
const LIFT_OFF := 0.1

var _poses: PoseBuilder
var _ual1: AnimationLibrary
var _ual2: AnimationLibrary
var _standing: Dictionary
# The long guns' carry, the stance their shots and reloads start from.
var _longgun_rest: Dictionary
var _crossbow_rest: Dictionary
var _rifle: KevinRifle
var _crossbow: KevinRifle
var _pistol: QuaterniusPistol


func _init() -> void:
	_poses = PoseBuilder.new()
	_ual1 = load(UAL1)
	_ual2 = load(UAL2)
	_standing = _poses.resolve(_poses.standing())
	var library := AnimationLibrary.new()

	library.add_animation("Bash", _keyed(_joined(["Shield_OneShot"]), {"impact": [BASH_IMPACT]}))
	library.add_animation("Throw", _keyed(_joined(["OverhandThrow"]), {"release": [THROW_RELEASE]}))
	library.add_animation("Punch", _keyed(_joined(["Melee_Hook", "Melee_Hook_Rec"]), {"impact": [PUNCH_IMPACT]}))
	library.add_animation("Claw", _keyed(_joined(["Zombie_Scratch"]), {"impact": [CLAW_IMPACT]}))

	var sword := KevinSword.new(_poses)
	library.add_animation("Stance_Sword", sword.stance())
	library.add_animation("Swing", _keyed(sword.swing(_source("Sword_Attack"), _frame), {"impact": [KevinSword.SWING_IMPACT]}))
	library.add_animation("Thrust", _keyed(sword.thrust(), {"impact": [KevinSword.THRUST_IMPACT]}))
	library.add_animation("Stance_Shield", _looped("Idle_Shield"))
	_pistol = QuaterniusPistol.new(_poses)
	library.add_animation("Stance_Pistol", _pistol.stance())
	var greatsword := KevinGreatsword.new(_poses)
	library.add_animation("Stance_Greatsword", greatsword.stance())
	library.add_animation("Heavy_Swing", _keyed(greatsword.swing(), {"impact": [HEAVY_IMPACT]}))
	library.add_animation("Heavy_Thrust", _keyed(greatsword.thrust(), {"impact": [KevinGreatsword.THRUST_IMPACT]}))
	_rifle = KevinRifle.new(_poses, load("res://scenes/weapons/rifle.tscn"))
	_crossbow = KevinRifle.new(_poses, load("res://scenes/weapons/crossbow.tscn"))
	_longgun_rest = _rifle.aimed()
	_crossbow_rest = _crossbow.aimed()
	library.add_animation("Stance_Longgun", _rifle.stance())
	library.add_animation("Stance_Crossbow", _crossbow.stance())
	var bow := KevinBow.new(_poses)
	library.add_animation("Stance_Bow", bow.stance())
	library.add_animation("Reload_Pistol", _pistol.reload())
	library.add_animation("Reload_Rifle", _rifle.reload())
	library.add_animation("Reload_Crossbow", _crossbow.hauled_reload())

	library.add_animation("Bite", _keyed(_poses.clip(0.9, false, _bite), {"impact": [BITE_IMPACT]}))
	library.add_animation("Gore", _keyed(_poses.clip(1.05, false, _gore), {"impact": [GORE_IMPACT]}))
	library.add_animation("Pistol_Shot", _shots(PISTOL_SHOTS, PISTOL_GAP, _pistol.aimed, _pistol.ready(),
		_pistol.lifted()))
	library.add_animation("Rifle_Burst", _shots(RIFLE_SHOTS, RIFLE_GAP, _shoulder_aim, _longgun_rest))
	library.add_animation("Crossbow_Shot", _shots(1, 0.2, func(since: float) -> Dictionary:
		return _crossbow.raised(_kick(since) * 6.0), _crossbow_rest))
	library.add_animation("Bow_Shot", _keyed(bow.shot(), {"release": [bow.release_time()]}))
	library.add_animation("Jump_Start", _keyed(_jump_start(), {"impact": [SINK + LIFT_OFF]}))

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


# A source clip as a loop: the idle it is, made to repeat.
func _looped(clip: String) -> Animation:
	var anim := _source(clip)
	return _poses.clip(anim.length, true, func(t: float, _length: float) -> Dictionary:
		return _frame(anim, t))


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


# Down into the crouch and up off the ground (see CROUCH).
func _jump_start() -> Animation:
	var land := _source("Jump_Land")
	var start := _source("Jump_Start")
	return _poses.clip(SINK + SPRUNG, false, func(t: float, _length: float) -> Dictionary:
		if t < SINK:
			return _frame(land, lerpf(RISEN, CROUCH, t / SINK))
		return _frame(start, t - SINK))


# Adds a Call Method track on CharacterModel: method name -> key times.
static func _keyed(anim: Animation, moments: Dictionary) -> Animation:
	var track := anim.add_track(Animation.TYPE_METHOD)
	anim.track_set_path(track, NodePath(".."))
	for method: String in moments:
		for time: float in moments[method]:
			anim.track_insert_key(track, time, {"method": StringName(method), "args": []})
	return anim


# --- Shots -----------------------------------------------------------------

# Up from the weapon's stance (`rest`) to the aim - through `lift` if given,
# the arm following the body - a beat on target, `count` shots `gap` apart,
# each a kick back and a settle with a release key on the kick, the aim held,
# then back down to the stance.
func _shots(count: int, gap: float, aim_at: Callable, rest: Dictionary, lift := {}) -> Animation:
	var first := AIM_UP + SETTLE
	var last_shot := first + (count - 1) * gap
	var length := last_shot + AIM_HOLD + LOWER
	var releases: Array[float] = []
	for i in count:
		releases.append(first + i * gap)
	var lags := {}
	for bone: String in ARM:
		lags[bone] = ARM_LAG
	var anim := _poses.clip(length, false, func(t: float, _length: float) -> Dictionary:
		if t <= AIM_UP:
			if lift.is_empty():
				return _poses.keyed(t, [[0.0, rest], [AIM_UP, aim_at.call(0.0)]])
			return _poses.flowing(t, AIM_UP, [[0.0, rest], [LIFT_AT, lift], [AIM_UP, aim_at.call(0.0)]], lags)
		if t < first:
			return aim_at.call(0.0)
		if t <= last_shot + AIM_HOLD:
			var since := fmod(t - first, gap) if t < last_shot else t - last_shot
			return aim_at.call(since)
		return _poses.keyed(t, [[last_shot + AIM_HOLD, aim_at.call(AIM_HOLD)], [length, rest]]))
	return _keyed(anim, {"release": releases})


# The kick of a shot, `since` seconds after it: back fast, settled by 0.15.
static func _kick(since: float) -> float:
	return exp(-since / 0.05) * (1.0 - exp(-since / 0.008))


# A long gun at the shoulder, the chest rocked back by the kick.
func _shoulder_aim(since: float) -> Dictionary:
	return _rifle.raised(_kick(since) * 6.0)


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

