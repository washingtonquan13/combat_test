extends SceneTree

# Lands the one-handed sword cuts from Mixamo's Sword And Shield Pack
# (tools/locomotion/takes/mixamo_duel.glb, made by
# tools/locomotion/mixamo_retarget.py with DUEL=1) in
# assets/weapon_animations.tres as Swing and Swing_B: the sword's
# swing and its alternate (data/animation_sequences/weapon_swing*.tres).
#
#   godot --headless --path . -s res://tools/locomotion/land_mixamo_sword.gd
#
# Run it last: after tools/make_weapon_animations.gd (which rewrites the whole
# library, with Kevin Iglesias' Swing) and tools/humanoid/carry_clips.gd.
#
# IN PLACE, no root motion: an attacker stands still, so the take is copied
# about its own origin and its lunge stays in the body, shortened to LUNGE of
# the take's (the hips go about 0.3 m forward and come back).
#
# RETIMED FOR WEIGHT, by marks, never by hand. Each take is cut into five
# stretches at four marks measured from the sword hand (tools/_probe prints
# them; this refines each to the hand's own slowest or furthest frame nearby
# and prints what it used):
#
#   start .. wind      the wind-up, played slower (WIND_UP times longer)
#   wind .. contact    the strike, squeezed to STRIKE of its length
#                      (never under STRIKE_MIN seconds)
#   contact .. through the follow-through, as shot
#   through ..         a moving hold: the next HOLD_SOURCE seconds of the take
#                      spread over HOLD seconds, the blade all but still
#   .. end             the recovery, RECOVER times faster, to the take's end
#
# The rate changes at the wind-up's top and the follow-through's end fall
# where the hand is nearly still; the one at contact is where the game's
# hitstop sits (UnitAnimator). impact() is keyed on contact.
#
# The takes were baked on the proof hero's own skeleton; this checks the
# imported one still is it, to the millimetre.

const TAKES := "res://tools/locomotion/takes/mixamo_duel.glb"
const MODEL := "res://scenes/character_models/proof_hero_model.tscn"
const LIBRARY_PATH := "res://assets/weapon_animations.tres"
const FPS := 60.0
const HAND := "RightHand"

const WIND_UP := 1.15
const STRIKE := 0.8
const STRIKE_MIN := 0.12
const HOLD_SOURCE := 0.05
const HOLD := 0.08
const RECOVER := 0.85
## How much of the take's lunge is kept. Mixamo's cuts step half a metre in;
## a melee attacker already stands at reach, so the whole step puts the fist,
## not the blade, on the target.
const LUNGE := 0.6
## How far either side of a mark the hand's own slowest (or furthest) frame is
## looked for.
const NEAR := 0.06

## Clips an earlier run landed and this one no longer does.
const RETIRED := ["Swing_C"]

## Source seconds. `wind_up` is that clip's own stretch (a long carry across
## the body is slow enough already). `hold` is that clip's own hold: a rising
## cut ends with the blade high, where a hold reads as a second wind-up, so it
## gets none.
const CLIPS := {
	"Swing": {"take": "ss_slash_1", "start": 0.03, "wind": 0.38, "contact": 0.60, "through": 0.90, "end": 1.5, "wind_up": WIND_UP, "hold": HOLD},
	"Swing_B": {"take": "ss_slash_3", "start": 0.14, "wind": 0.60, "contact": 0.80, "through": 1.15, "end": 1.56, "wind_up": 1.0, "hold": HOLD_SOURCE},
}

var _skeleton: Skeleton3D
var _player: AnimationPlayer
var _hand: int


func _initialize() -> void:
	_land.call_deferred()


func _land() -> void:
	await process_frame
	var model: Node3D = (load(MODEL) as PackedScene).instantiate()
	root.add_child(model)
	var hero: Skeleton3D = model.find_child("GeneralSkeleton", true, false)
	var takes: Node3D = (load(TAKES) as PackedScene).instantiate()
	root.add_child(takes)
	_skeleton = takes.find_child("GeneralSkeleton", true, false)
	_player = takes.find_children("*", "AnimationPlayer", true, false)[0]
	_hand = _skeleton.find_bone(HAND)
	if not _same_rest(hero):
		quit(1)
		return

	var library: AnimationLibrary = load(LIBRARY_PATH)
	for old: String in RETIRED:
		if library.has_animation(old):
			library.remove_animation(old)
	for clip: String in CLIPS:
		var made := _retimed(clip, CLIPS[clip])
		if library.has_animation(clip):
			library.remove_animation(clip)
		library.add_animation(clip, made)
	print("SWORD saved ", LIBRARY_PATH, " err ", _save_keeping_uid(library, LIBRARY_PATH))
	quit()


func _retimed(clip: String, spec: Dictionary) -> Animation:
	var take: String = spec.take
	_player.play(take)
	var wind := _stillest(spec.wind)
	var contact := _furthest(spec.contact)
	var through := _stillest(spec.through)
	# Source time against output time, straight between these points.
	var strike: float = maxf(STRIKE_MIN, (contact - wind) * STRIKE)
	var src: Array[float] = [spec.start, wind, contact, through, through + HOLD_SOURCE, spec.end]
	var out: Array[float] = [0.0]
	out.append(out[-1] + (wind - spec.start) * float(spec.wind_up))
	out.append(out[-1] + strike)
	out.append(out[-1] + (through - contact))
	out.append(out[-1] + float(spec.hold))
	out.append(out[-1] + (spec.end - through - HOLD_SOURCE) / RECOVER)

	var anim := Animation.new()
	anim.length = out[-1]
	anim.step = 1.0 / FPS
	anim.loop_mode = Animation.LOOP_NONE
	var tracks: Array[int] = []
	for bone in _skeleton.get_bone_count():
		var at := anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(at, NodePath("%GeneralSkeleton:" + _skeleton.get_bone_name(bone)))
		tracks.append(at)
	var hips := _skeleton.find_bone("Hips")
	var hips_track := anim.add_track(Animation.TYPE_POSITION_3D)
	anim.track_set_path(hips_track, NodePath("%GeneralSkeleton:Hips"))

	_player.seek(spec.start, true)
	var hips_from: float = _skeleton.get_bone_pose_position(hips).z
	var frames: int = ceili(anim.length * FPS)
	for frame in frames + 1:
		var time: float = minf(frame / FPS, anim.length)
		_player.seek(_source_time(time, src, out), true)
		for bone in _skeleton.get_bone_count():
			anim.rotation_track_insert_key(tracks[bone], time, _skeleton.get_bone_pose_rotation(bone))
		# A position track is stored over the skeleton's motion scale.
		var at_hips: Vector3 = _skeleton.get_bone_pose_position(hips)
		at_hips.z = hips_from + (at_hips.z - hips_from) * LUNGE
		anim.position_track_insert_key(hips_track, time, at_hips / _skeleton.motion_scale)

	var method := anim.add_track(Animation.TYPE_METHOD)
	anim.track_set_path(method, NodePath(".."))
	anim.track_insert_key(method, out[2], {"method": &"impact", "args": []})

	_player.seek(spec.end, true)
	var last := _hand_at()
	_player.seek(_player.current_animation_length, true)
	print("SWORD %s from %s: wind %.3f contact %.3f through %.3f (source) | length %.3f impact %.3f hold %.3f-%.3f | cut %.0f mm short of the take's last pose" % [
		clip, take, wind, contact, through, anim.length, out[2], out[3], out[4], last.distance_to(_hand_at()) * 1000.0])
	return anim


func _source_time(time: float, src: Array[float], out: Array[float]) -> float:
	for i in range(1, out.size()):
		if time <= out[i] or i == out.size() - 1:
			return lerpf(src[i - 1], src[i], clampf(inverse_lerp(out[i - 1], out[i], time), 0.0, 1.0))
	return src[-1]


func _hand_at() -> Vector3:
	return _skeleton.get_bone_global_pose(_hand).origin


func _hand_speed(time: float) -> float:
	_player.seek(time - 0.5 / FPS, true)
	var before := _hand_at()
	_player.seek(time + 0.5 / FPS, true)
	return before.distance_to(_hand_at()) * FPS


## The time within NEAR of `mark` the hand moves slowest.
func _stillest(mark: float) -> float:
	var best := mark
	var slowest := INF
	var time := mark - NEAR
	while time <= mark + NEAR:
		var speed := _hand_speed(time)
		if speed < slowest:
			slowest = speed
			best = time
		time += 1.0 / FPS
	return best


## The time within NEAR of `mark` the hand is furthest forward.
func _furthest(mark: float) -> float:
	var best := mark
	var far := -INF
	var time := mark - NEAR
	while time <= mark + NEAR:
		_player.seek(time, true)
		if _hand_at().z > far:
			far = _hand_at().z
			best = time
		time += 1.0 / FPS
	return best


func _same_rest(hero: Skeleton3D) -> bool:
	var worst := 0.0
	for i in _skeleton.get_bone_count():
		var j: int = hero.find_bone(_skeleton.get_bone_name(i))
		if j < 0:
			push_error("the hero has no bone %s" % _skeleton.get_bone_name(i))
			return false
		var a: Transform3D = _skeleton.get_bone_global_rest(i)
		var b: Transform3D = hero.get_bone_global_rest(j)
		worst = maxf(worst, a.origin.distance_to(b.origin))
		for k in 3:
			worst = maxf(worst, (a.basis[k] - b.basis[k]).length() * 0.1)
	print("the takes' skeleton is the hero's to %.2f mm" % (worst * 1000.0))
	if worst > 0.001:
		push_error("the takes are not on the hero's skeleton")
		return false
	return true


# A save from a script drops the file's uid, and scenes refer to the file by it.
func _save_keeping_uid(library: AnimationLibrary, path: String) -> Error:
	var uid := FileAccess.get_file_as_string(path).get_slice("\n", 0).get_slice(" uid=", 1).trim_suffix("]")
	var err := ResourceSaver.save(library, path)
	var text := FileAccess.get_file_as_string(path)
	var end := text.find("]")
	if err == OK and uid != "" and not text.substr(0, end).contains(" uid="):
		FileAccess.open(path, FileAccess.WRITE).store_string(text.insert(end, " uid=" + uid))
	return err
