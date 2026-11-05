extends SceneTree

# Generates assets/ladder_animations.tres: the ladder climb, cut from CMU
# motion capture (mocap.cs.cmu.edu, subject 14, take 35, "climb ladder").
# The take is converted ASF/AMC -> BVH -> GLB outside the project and
# imported under assets/cmu_ladder/ with a humanoid BoneMap, so its tracks
# already name our bones. The import must enable the rest fixer's
# fix_silhouette: CMU's rest has the femurs angled 20 degrees out, and
# without it every pose is retargeted relative to that splay, turning our
# straight-legged model's knees in until the legs cross. Only the Hips
# needs our scale (the import
# normalizes it to hip heights), our facing, and the climb taken out.
#
#   godot --headless --path . -s res://tools/make_ladder_animations.gd
#
# Climb_Up is in place: one rung per cycle, the body's rise (and its drift
# toward the ladder) subtracted so the unit's own movement supplies it.
# The clip's metadata "rise" is the height one cycle climbs; UnitAnimator
# plays it at climb_speed / (rise / length) so the feet keep pace with the
# unit, and backwards for a descent. The take's own descent (frames
# 213-261) was cut too and dropped: its retargeted forearms twist 60
# degrees and cross the hands in front of the body. The Hips sit relative
# to the rung the support foot is on at the cycle's start: the unit's
# origin is that rung.
#
# The CMU data is free for any use; the lab asks for this credit:
# "The data used in this project was obtained from mocap.cs.cmu.edu.
# The database was created with funding from NSF EIA-0196217."

const OUT := "res://assets/ladder_animations.tres"
const TAKE := "res://assets/cmu_ladder/cmu_14_35.glb"
const FPS := 30.0
# Our Hips stand this high; the import's Hips track is in hip heights.
const HIPS := 0.917
# The capture's rest hips height (amc2bvh's root offset for subject 14).
const CMU_HIPS := 0.941
# Frames to crossfade the cycle's end into its start.
const BLEND := 8

# One rung per cycle, frames of take 14_35 from foot lift to the same
# foot's next lift; foot = the support foot's height (capture metres) at
# the cycle's start.
const CYCLES := {
	"Climb_Up": {"from": 87, "to": 128, "foot": 0.415},
}


func _init() -> void:
	var source := _source(TAKE)
	var facing := _facing_fix(source)
	var library := AnimationLibrary.new()
	for clip: String in CYCLES:
		var c: Dictionary = CYCLES[clip]
		library.add_animation(clip, _cycle(source, c["from"], c["to"], c["foot"], facing))
	var err := ResourceSaver.save(library, OUT)
	print("ladder animations: saved %s (%s)" % [OUT, error_string(err)])
	quit(0 if err == OK else 1)


static func _source(path: String) -> Animation:
	var scene: Node = (load(path) as PackedScene).instantiate()
	var player: AnimationPlayer = scene.find_children("*", "AnimationPlayer", true, false)[0]
	var anim: Animation = player.get_animation(player.get_animation_list()[0]).duplicate(true)
	scene.free()
	return anim


static func _hips_track(anim: Animation, type: int) -> int:
	for track in anim.get_track_count():
		if anim.track_get_type(track) == type and String(anim.track_get_path(track).get_concatenated_subnames()) == "Hips":
			return track
	return -1


# The yaw turning the climber's Hips to face where our Idle's Hips face
# (the model's front), averaged over the climb so a lean doesn't skew it.
static func _facing_fix(anim: Animation) -> Quaternion:
	var idle: Animation = (load("res://assets/unit_animations.tres") as AnimationLibrary).get_animation("Idle")
	var want := _flat_forward(idle.rotation_track_interpolate(_hips_track(idle, Animation.TYPE_ROTATION_3D), 0.0))
	var track := _hips_track(anim, Animation.TYPE_ROTATION_3D)
	var have := Vector3.ZERO
	for f in range(87, 129, 2):
		have += _flat_forward(anim.rotation_track_interpolate(track, f / FPS))
	have = Vector3(have.x, 0.0, have.z).normalized()
	return Quaternion(Vector3.UP, have.signed_angle_to(want, Vector3.UP))


static func _flat_forward(q: Quaternion) -> Vector3:
	var f := Basis(q).z
	return Vector3(f.x, 0.0, f.z).normalized()


# Frames from..to as a loop: every track sampled per frame, the Hips'
# linear rise and drift over the cycle subtracted, the last BLEND frames
# crossfaded into the frames just before `from` (same trend) so the end
# meets the start exactly.
static func _cycle(source: Animation, from: int, to: int, foot: float, facing: Quaternion) -> Animation:
	var frames: int = to - from
	var anim := Animation.new()
	anim.length = frames / FPS
	anim.loop_mode = Animation.LOOP_LINEAR
	var hips_pos := _hips_track(source, Animation.TYPE_POSITION_3D)
	var p0: Vector3 = source.position_track_interpolate(hips_pos, from / FPS)
	var p1: Vector3 = source.position_track_interpolate(hips_pos, to / FPS)
	var step: Vector3 = p1 - p0
	var rest := foot / CMU_HIPS
	anim.set_meta("rise", step.y * HIPS)
	for track in source.get_track_count():
		var type := source.track_get_type(track)
		if type != Animation.TYPE_ROTATION_3D and type != Animation.TYPE_POSITION_3D:
			continue
		var is_hips := String(source.track_get_path(track).get_concatenated_subnames()) == "Hips"
		if type == Animation.TYPE_POSITION_3D and not is_hips:
			continue
		var out := anim.add_track(type)
		anim.track_set_path(out, source.track_get_path(track))
		for i in frames + 1:
			var value: Variant = _sample(source, track, from + i, from, frames, p0, step, rest)
			if i > frames - BLEND:
				var w: float = float(i - (frames - BLEND)) / BLEND
				var early: Variant = _sample(source, track, from + i - frames, from, frames, p0, step, rest)
				value = value.slerp(early, w) if type == Animation.TYPE_ROTATION_3D else value.lerp(early, w)
			if is_hips:
				value = facing * value if type == Animation.TYPE_ROTATION_3D else facing * (value as Vector3) * HIPS
			if type == Animation.TYPE_ROTATION_3D:
				anim.rotation_track_insert_key(out, i / FPS, value)
			else:
				anim.position_track_insert_key(out, i / FPS, value)
	return anim


# Frame f of a track; for the Hips position, minus the cycle's trend (so
# frames before `from` continue it) and relative to the support rung.
static func _sample(source: Animation, track: int, f: int, from: int, frames: int, p0: Vector3, step: Vector3, rest: float) -> Variant:
	if source.track_get_type(track) == Animation.TYPE_ROTATION_3D:
		return source.rotation_track_interpolate(track, f / FPS)
	var p: Vector3 = source.position_track_interpolate(track, f / FPS)
	var trend: Vector3 = p0 + step * (float(f - from) / frames)
	var d: Vector3 = p - trend
	return Vector3(d.x, p0.y - rest + d.y, d.z)
