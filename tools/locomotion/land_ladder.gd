extends SceneTree

# Lands the Mixamo ladder takes (tools/locomotion/takes/mixamo_ladder.glb,
# made by tools/locomotion/mixamo_retarget.py with LADDER=1) in
# assets/ladder_animations.tres as Climb_Up, Climb_Over_Top, Climb_On_Top,
# Climb_Mount and Climb_Dismount, replacing the CMU loop and the blocked climb-over that
# tools/make_ladder_animations.gd made.
#
#   godot --headless --path . -s res://tools/locomotion/land_ladder.gd
#
# IN PLACE, like every clip (no root motion). The takes climb a ladder of
# their own; each is baked back over a root that travels as the unit does on
# ours (UnitMovement._climb_step, Ladder.climb_waypoints), so nothing of the
# take's own travel is left in the Hips:
#   Climb_Up        the loop. Its root rises steadily by the cycle's rise:
#                   the Hips' rise from the first frame to the last (a
#                   Mixamo loop's last frame is its first, a cycle on). One
#                   cycle climbs two rungs, a step of each foot.
#   Climb_Over_Top  from "Climbing To Top": the root goes up `over_rungs`
#                   rungs and then `over_reach` onto the landing, at one
#                   steady speed (stop -> elbow -> off).
#   Climb_On_Top    Climb_Over_Top played backwards, frame for frame (there
#                   is no Mixamo climb down); its plants run backwards too.
#   Climb_Mount     from "Start Climbing Ladder", from MOUNT_FROM on: the
#                   take stands with its back to its ladder, beside it, and
#                   turns; from MOUNT_FROM it walks in sideways toward the
#                   climb line, steps up and ends on the loop's first pose.
#                   Framed on its LAST frame (the loop's rule below), its
#                   root goes in a straight line, steadily, from under its
#                   Hips at its first frame, on the ground, to the climb
#                   root at its last, as UnitMovement walks the mount leg
#                   (Ladder.climb_waypoints: on -> mount).
#   Climb_Dismount  Climb_Mount backwards.
#
# THE ROOT. Both takes start on the same pose, the loop's first frame, so
# one rule places the root in both and the loop hands to the climb-over on
# the rungs it is on. The ladder is ahead of the body (the take's toes from
# its Hips, level), turned onto the model's +Z, the way our climber faces.
# The root is on the climb line: RUNG_OFFSET behind the plane the toes are
# on, across at the middle of the hands, and as high as the rung the lower
# foot stands on at the first frame (its toes TOE_OVER_RUNG over it). The
# unit's origin on a ladder is that rung, as UnitAnimator phases the loop.
#
# THE RUNGS (metadata, read by Ladder and LadderGrip):
#   rise          one cycle's climb (m); UnitAnimator plays the loop to it.
#   rung          the rung spacing: rise / RUNGS_PER_CYCLE.
#   over_rungs    how many rungs below the landing the climb-over starts:
#                 its climb to the landing floor in whole rungs.
#   over_reach    how far onto the landing it ends standing, from the line.
#   plants        {limb: PackedFloat32Array}, a weight per frame (FPS) of
#                 how still the hand or foot is in the take (still is on
#                 a rung, or on the landing).
#   contact       {limb: float}: how high the hand's or ankle's bone sits
#                 over the rung it holds, on average while planted.
#   mount_from    (Climb_Mount) where its root starts, from where it ends,
#                 in the ladder's frame (+Z the way the climber faces; y is
#                 the drop to the ground): Ladder starts the mount there.
#   mount_heading (Climb_Mount) the way the body faces at its first frame,
#                 radians about Y off +Z: the walk comes in that way.
#
# THE LANDING. The take's floor is not a whole number of rungs over the
# rung it starts on; ours is (Ladder counts its rungs down from the top).
# The difference (a few cm) is taken out of the Hips over the clip, a
# straight ramp from none at the first frame to all of it at the last; the
# planted hands and feet are put back on the rungs by LadderGrip. That ramp
# is a workaround, logged in docs/systems/unit.md.
#
# The clips were baked on the proof hero's own skeleton; this checks the
# imported one still is it, to the millimetre.

const TAKES := "res://tools/locomotion/takes/mixamo_ladder.glb"
const MODEL := "res://scenes/character_models/proof_hero_model.tscn"
const OUT := "res://assets/ladder_animations.tres"
const FPS := 30.0
const LIMBS := ["LeftHand", "RightHand", "LeftFoot", "RightFoot"]
const RUNGS_PER_CYCLE := 2.0
## The root this far behind the toes' plane (world/ladder.gd's RUNG_OFFSET:
## where its rungs are built from the climb line).
const RUNG_OFFSET := 0.15
## A standing foot's toe bone over the middle of its rung: the rung's
## radius and the sole under the ball.
const TOE_OVER_RUNG := 0.045
## A limb slower than STILL_SLOW (m/s, in the take's world) is wholly
## planted, faster than STILL_FAST not at all, smoothstepped between. A foot
## is timed by its toes (it stands on the ball, the ankle rolls), a hand by
## its wrist. A holding limb still slides 0.1-0.28 m/s in these takes (the
## mocap's own slip): SPEEDS=1 in the environment prints every frame's.
const STILL_SLOW := 0.2
const STILL_FAST := 0.5
## The mount's first frame in the take: walking in sideways toward the climb
## line (the Hips facing ~82 deg off the ladder). Before it the take stands
## idle with its back to the ladder and swings round on the spot, which no
## walk arriving at a ladder does.
const MOUNT_FROM := 30

var _skeleton: Skeleton3D
var _player: AnimationPlayer
var _hips: int
var _hero: Skeleton3D


func _initialize() -> void:
	_land.call_deferred()


func _land() -> void:
	await process_frame
	var model: Node3D = (load(MODEL) as PackedScene).instantiate()
	root.add_child(model)
	_hero = model.find_child("GeneralSkeleton", true, false)
	var takes: Node3D = (load(TAKES) as PackedScene).instantiate()
	root.add_child(takes)
	_skeleton = takes.find_child("GeneralSkeleton", true, false)
	_player = takes.find_children("*", "AnimationPlayer", true, false)[0]
	_hips = _skeleton.find_bone("Hips")
	if not _same_rest():
		quit(1)
		return

	var up: Dictionary = _sample("ladder_up")
	var top: Dictionary = _sample("ladder_top")
	var library: AnimationLibrary = load(OUT)

	print("\nCLIMB_UP")
	var loop: Dictionary = _frame(up)
	var n: int = up.frames
	var rise: float = (up.hips[n - 1] as Transform3D).origin.y - (up.hips[0] as Transform3D).origin.y
	var rung: float = rise / RUNGS_PER_CYCLE
	var roots: Array[Transform3D] = []
	for f in n:
		roots.append(Transform3D(Basis.IDENTITY, loop.root0 + Vector3.UP * rise * f / (n - 1)))
	var climb: Animation = _bake(up, loop, roots, PackedFloat32Array(), true)
	var plants: Dictionary = _plants(up, loop, true, Vector3.UP * rise)
	climb.set_meta("rise", rise)
	climb.set_meta("rung", rung)
	climb.set_meta("plants", plants)
	climb.set_meta("contact", _contacts(up, loop, plants, rung, loop.root0.y, INF))
	print("  %.2f s, rises %.3f m a cycle (a rung every %.3f m), %.2f m/s at 1x" % [climb.length, rise, rung,
		rise / climb.length])

	print("\nCLIMB_OVER_TOP")
	var over: Dictionary = _frame(top)
	var m: int = top.frames
	print("  starts %.1f cm off the loop's root" % ((over.root0 as Vector3).distance_to(loop.root0) * 100.0))
	# The landing floor: the feet at the end, standing, less their rest height.
	var toes_rest: float = (_skeleton.get_bone_global_rest(_skeleton.find_bone("LeftToes")).origin.y
		+ _skeleton.get_bone_global_rest(_skeleton.find_bone("RightToes")).origin.y) * 0.5
	var floor_y: float = ((top.at["LeftToes"][m - 1] as Vector3).y + (top.at["RightToes"][m - 1] as Vector3).y) * 0.5
	floor_y = (over.basis * Vector3(0.0, floor_y, 0.0)).y - toes_rest
	var climbs: float = floor_y - over.root0.y
	var over_rungs: int = roundi(climbs / rung)
	var lift: float = over_rungs * rung
	var ramp: float = climbs - lift
	var end_hips: Vector3 = over.basis * (top.hips[m - 1] as Transform3D).origin
	var reach: float = end_hips.z - over.root0.z
	print("  climbs %.3f m to the floor: %d rungs (%.3f m), %+.1f cm ramped out" % [climbs, over_rungs, lift,
		ramp * 100.0])
	print("  ends standing %.3f m onto the landing, %+.1f cm across" % [reach, (end_hips.x - over.root0.x) * 100.0])
	var path: Array[Transform3D] = []
	var down := PackedFloat32Array()
	for f in m:
		var along: float = float(f) / (m - 1) * (lift + reach)
		path.append(Transform3D(Basis.IDENTITY, over.root0 + Vector3(0.0, minf(along, lift), maxf(along - lift, 0.0))))
		down.append(ramp * f / (m - 1))
	var climb_over: Animation = _bake(top, over, path, down, false)
	var over_plants: Dictionary = _plants(top, over, false, Vector3.ZERO)
	climb_over.set_meta("over_rungs", over_rungs)
	climb_over.set_meta("over_reach", reach)
	climb_over.set_meta("rung", rung)
	climb_over.set_meta("plants", over_plants)
	climb_over.set_meta("contact", climb.get_meta("contact"))
	print("  %.2f s over %.2f m of root: %.2f m/s at 1x" % [climb_over.length, lift + reach,
		(lift + reach) / climb_over.length])

	print("\nCLIMB_ON_TOP")
	var climb_on: Animation = _reversed(climb_over)
	var on_plants: Dictionary = {}
	for limb: String in over_plants:
		var w: PackedFloat32Array = over_plants[limb].duplicate()
		w.reverse()
		on_plants[limb] = w
	climb_on.set_meta("plants", on_plants)
	climb_on.set_meta("rung", rung)
	climb_on.set_meta("contact", climb.get_meta("contact"))
	print("  Climb_Over_Top backwards, %.2f s" % climb_on.length)

	print("\nCLIMB_MOUNT")
	var start: Dictionary = _trimmed(_sample("ladder_start"), MOUNT_FROM)
	var k: int = start.frames
	var mount: Dictionary = _frame(start, k - 1)
	var first_toes: float = minf(((mount.basis as Basis) * (start.at["LeftToes"][0] as Vector3)).y,
		((mount.basis as Basis) * (start.at["RightToes"][0] as Vector3)).y)
	var ground: float = first_toes - toes_rest
	var first_hips: Vector3 = (mount.basis as Basis) * (start.hips[0] as Transform3D).origin
	var from := Vector3(first_hips.x, ground, first_hips.z)
	var facing: Vector3 = (mount.basis as Basis) * (start.hips[0] as Transform3D).basis.z
	var heading: float = atan2(facing.x, facing.z)
	var end_pose: Vector3 = (mount.basis as Basis) * (start.hips[k - 1] as Transform3D).origin
	var loop_pose: Vector3 = (loop.basis as Basis) * (up.hips[0] as Transform3D).origin
	print("  ends with its Hips %.1f cm off the loop's first frame (each from its root)" % (
		(end_pose - mount.root0).distance_to(loop_pose - loop.root0) * 100.0))
	var mount_path: Array[Transform3D] = []
	for f in k:
		mount_path.append(Transform3D(Basis.IDENTITY, from.lerp(mount.root0, float(f) / (k - 1))))
	var climb_mount: Animation = _bake(start, mount, mount_path, PackedFloat32Array(), false)
	var mount_plants: Dictionary = _plants(start, mount, false, Vector3.ZERO)
	var mount_from: Vector3 = from - mount.root0
	climb_mount.set_meta("mount_from", mount_from)
	climb_mount.set_meta("mount_heading", heading)
	climb_mount.set_meta("rung", rung)
	climb_mount.set_meta("plants", mount_plants)
	climb_mount.set_meta("contact", climb.get_meta("contact"))
	print("  %.2f s; starts %s from its end (%.2f m down), facing %+.0f deg" % [climb_mount.length,
		mount_from.snapped(Vector3.ONE * 0.001), -mount_from.y, rad_to_deg(heading)])

	print("\nCLIMB_DISMOUNT")
	var climb_dismount: Animation = _reversed(climb_mount)
	var dismount_plants: Dictionary = {}
	for limb: String in mount_plants:
		var w: PackedFloat32Array = mount_plants[limb].duplicate()
		w.reverse()
		dismount_plants[limb] = w
	climb_dismount.set_meta("plants", dismount_plants)
	climb_dismount.set_meta("rung", rung)
	climb_dismount.set_meta("contact", climb.get_meta("contact"))
	print("  Climb_Mount backwards, %.2f s" % climb_dismount.length)

	for pair: Array in [["Climb_Up", climb], ["Climb_Over_Top", climb_over], ["Climb_On_Top", climb_on],
			["Climb_Mount", climb_mount], ["Climb_Dismount", climb_dismount]]:
		if library.has_animation(pair[0]):
			library.remove_animation(pair[0])
		library.add_animation(StringName(pair[0]), pair[1])
	var err: Error = ResourceSaver.save(library, OUT)
	print("\n%s: %s" % [OUT, error_string(err)])
	quit(0 if err == OK else 1)


func _same_rest() -> bool:
	var worst := 0.0
	for i in _skeleton.get_bone_count():
		var j: int = _hero.find_bone(_skeleton.get_bone_name(i))
		if j < 0:
			push_error("the hero has no bone %s" % _skeleton.get_bone_name(i))
			return false
		var a: Transform3D = _skeleton.get_bone_global_rest(i)
		var b: Transform3D = _hero.get_bone_global_rest(j)
		worst = maxf(worst, a.origin.distance_to(b.origin))
		for k in 3:
			worst = maxf(worst, (a.basis[k] - b.basis[k]).length() * 0.1)
	print("the takes' skeleton is the hero's to %.2f mm" % (worst * 1000.0))
	if worst > 0.001:
		push_error("the takes are not on the hero's skeleton")
		return false
	return true


## Every frame of take `name`, skeleton space: {name, anim, frames, hips,
## parents, at: {bone: PackedVector3Array}} for the limbs and the toes.
func _sample(name: String) -> Dictionary:
	var anim: Animation = _player.get_animation(name)
	var n: int = roundi(anim.length * FPS) + 1
	var bones: Array = LIMBS + ["LeftToes", "RightToes"]
	var at: Dictionary = {}
	for b: String in bones:
		at[b] = PackedVector3Array()
	var hips: Array[Transform3D] = []
	var parents: Array[Transform3D] = []
	_player.play(name)
	for f in n:
		_player.seek(minf(f / FPS, anim.length), true)
		hips.append(_skeleton.get_bone_global_pose(_hips))
		var p: int = _skeleton.get_bone_parent(_hips)
		parents.append(_skeleton.get_bone_global_pose(p) if p >= 0 else Transform3D.IDENTITY)
		for b: String in bones:
			at[b].append(_skeleton.get_bone_global_pose(_skeleton.find_bone(b)).origin)
	_player.stop()
	return {"name": name, "anim": anim, "frames": n, "hips": hips, "parents": parents, "at": at}


## The take turned to face +Z (its ladder ahead, by its toes from its Hips
## at frame `on`, the first by default), and its root there (see THE ROOT):
## {basis, root0}.
func _frame(take: Dictionary, on: int = 0) -> Dictionary:
	var at: Dictionary = take.at
	var hips: Vector3 = (take.hips[on] as Transform3D).origin
	var toes: Vector3 = ((at["LeftToes"][on] as Vector3) + (at["RightToes"][on] as Vector3)) * 0.5
	var ahead := Vector3(toes.x - hips.x, 0.0, toes.z - hips.z).normalized()
	var basis := Basis(Vector3.UP, ahead.signed_angle_to(Vector3.BACK, Vector3.UP))
	var lower: String = "LeftToes" if (at["LeftToes"][on] as Vector3).y < (at["RightToes"][on] as Vector3).y else "RightToes"
	var foot: Vector3 = basis * (at[lower][on] as Vector3)
	var hands: Vector3 = basis * (((at["LeftHand"][on] as Vector3) + (at["RightHand"][on] as Vector3)) * 0.5)
	var root0 := Vector3(hands.x, foot.y - TOE_OVER_RUNG, foot.z - RUNG_OFFSET)
	print("  %s faces %+.1f deg off the model's front; the root at %s, %s's rung" % [take.name,
		rad_to_deg(basis.get_euler().y), root0.snapped(Vector3.ONE * 0.001), lower])
	return {"basis": basis, "root0": root0}


## `take` baked in place over `roots` (one per frame, turned space), its
## Hips also brought down by `down` (per frame, m; empty for none).
func _bake(take: Dictionary, frame: Dictionary, roots: Array[Transform3D], down: PackedFloat32Array,
		loops: bool) -> Animation:
	var src: Animation = take.anim
	var turn := Transform3D(frame.basis, Vector3.ZERO)
	var anim := Animation.new()
	anim.length = src.length
	anim.step = 1.0 / FPS
	anim.loop_mode = Animation.LOOP_LINEAR if loops else Animation.LOOP_NONE
	for t in src.get_track_count():
		var bone: String = String(src.track_get_path(t).get_concatenated_subnames())
		var kind: Animation.TrackType = src.track_get_type(t)
		if bone == "" or bone == "Root" or _skeleton.find_bone(bone) < 0:
			continue
		if bone == "Hips" and (kind == Animation.TYPE_POSITION_3D or kind == Animation.TYPE_ROTATION_3D):
			continue
		var copy: int = anim.add_track(kind)
		anim.track_set_path(copy, NodePath("%%GeneralSkeleton:%s" % bone))
		anim.track_set_interpolation_type(copy, src.track_get_interpolation_type(t))
		for k in src.track_get_key_count(t):
			anim.track_insert_key(copy, src.track_get_key_time(t, k), src.track_get_key_value(t, k))
	var pos: int = anim.add_track(Animation.TYPE_POSITION_3D)
	var rot: int = anim.add_track(Animation.TYPE_ROTATION_3D)
	for tr in [pos, rot]:
		anim.track_set_path(tr, NodePath("%GeneralSkeleton:Hips"))
	var hips: Array[Transform3D] = take.hips
	var parents: Array[Transform3D] = take.parents
	for f in take.frames:
		var placed: Transform3D = turn * hips[f]
		if not down.is_empty():
			placed.origin.y -= down[f]
		var local: Transform3D = parents[f].affine_inverse() * roots[f].affine_inverse() * placed
		# A Hips position track is kept over the skeleton's motion scale.
		anim.position_track_insert_key(pos, minf(f / FPS, anim.length), local.origin / _skeleton.motion_scale)
		anim.rotation_track_insert_key(rot, minf(f / FPS, anim.length), local.basis.orthonormalized().get_rotation_quaternion())
	return anim


## Each limb's plant weight per frame: how still it is in the take's world
## (STILL_SLOW, STILL_FAST). A loop's neighbours wrap a cycle (`cycle`) on.
func _plants(take: Dictionary, frame: Dictionary, loops: bool, cycle: Vector3) -> Dictionary:
	var n: int = take.frames
	var out: Dictionary = {}
	var said := " "
	for limb: String in LIMBS:
		var at: PackedVector3Array = take.at[(limb as String).replace("Foot", "Toes")]
		var w := PackedFloat32Array()
		var share := 0.0
		for f in n:
			var a: Vector3
			var b: Vector3
			if loops:
				a = at[f - 1] if f > 0 else at[n - 2] - (frame.basis as Basis).inverse() * cycle
				b = at[f + 1] if f < n - 1 else at[1] + (frame.basis as Basis).inverse() * cycle
			else:
				a = at[maxi(f - 1, 0)]
				b = at[mini(f + 1, n - 1)]
			var steps: float = 2.0 if (loops or (f > 0 and f < n - 1)) else 1.0
			var speed: float = a.distance_to(b) * FPS / steps
			if OS.get_environment("SPEEDS") == "1":
				print("    %s f%d %.3f m/s" % [limb, f, speed])
			w.append(1.0 - smoothstep(STILL_SLOW, STILL_FAST, speed))
			share += w[f] / n
		out[limb] = w
		said += " %s %3.0f%%" % [limb, share * 100.0]
	print("  planted:" + said)
	return out


## Each limb's height over the rung it holds while planted (circular mean
## over the rung grid from `rung0`, spacing `rung`), and how far its
## plants stray from that. Planted frames above `below` are left out.
func _contacts(take: Dictionary, frame: Dictionary, plants: Dictionary, rung: float, rung0: float,
		below: float) -> Dictionary:
	var out: Dictionary = {}
	for limb: String in LIMBS:
		var at: PackedVector3Array = take.at[limb]
		var s := 0.0
		var c := 0.0
		var heights: Array = []
		for f in take.frames:
			var w: float = plants[limb][f]
			var y: float = ((frame.basis as Basis) * at[f]).y
			if w < 0.9 or y > below:
				continue
			var a: float = TAU * (y - rung0) / rung
			s += sin(a)
			c += cos(a)
			heights.append(y)
		var off: float = fposmod(atan2(s, c) / TAU * rung, rung)
		var worst := 0.0
		for y: float in heights:
			var k: float = roundf((y - rung0 - off) / rung)
			worst = maxf(worst, absf(y - rung0 - off - k * rung))
		out[limb] = off
		print("  %-9s holds %.3f m over its rung, plants within %.1f cm of the grid" % [limb, off, worst * 100.0])
	return out


## `take` from frame `first` on: its samples cut there, and its clip
## resampled a frame at a time from that time so it starts at 0.
func _trimmed(take: Dictionary, first: int) -> Dictionary:
	var src: Animation = take.anim
	var from: float = first / FPS
	var n: int = take.frames - first
	var anim := Animation.new()
	anim.length = src.length - from
	anim.step = 1.0 / FPS
	for t in src.get_track_count():
		var kind: Animation.TrackType = src.track_get_type(t)
		if kind != Animation.TYPE_POSITION_3D and kind != Animation.TYPE_ROTATION_3D and kind != Animation.TYPE_SCALE_3D:
			continue
		var copy: int = anim.add_track(kind)
		anim.track_set_path(copy, src.track_get_path(t))
		anim.track_set_interpolation_type(copy, src.track_get_interpolation_type(t))
		for f in n:
			var time: float = minf(from + f / FPS, src.length)
			var value: Variant
			match kind:
				Animation.TYPE_POSITION_3D:
					value = src.position_track_interpolate(t, time)
				Animation.TYPE_ROTATION_3D:
					value = src.rotation_track_interpolate(t, time)
				_:
					value = src.scale_track_interpolate(t, time)
			anim.track_insert_key(copy, minf(f / FPS, anim.length), value)
	var at: Dictionary = {}
	for b: String in take.at:
		at[b] = (take.at[b] as PackedVector3Array).slice(first)
	var hips: Array[Transform3D] = []
	hips.assign((take.hips as Array).slice(first))
	var parents: Array[Transform3D] = []
	parents.assign((take.parents as Array).slice(first))
	return {"name": take.name, "anim": anim, "frames": n, "hips": hips, "parents": parents, "at": at}


## `anim` played backwards, key for key.
func _reversed(anim: Animation) -> Animation:
	var out := Animation.new()
	out.length = anim.length
	out.step = anim.step
	out.loop_mode = Animation.LOOP_NONE
	for t in anim.get_track_count():
		var copy: int = out.add_track(anim.track_get_type(t))
		out.track_set_path(copy, anim.track_get_path(t))
		out.track_set_interpolation_type(copy, anim.track_get_interpolation_type(t))
		for k in anim.track_get_key_count(t):
			out.track_insert_key(copy, maxf(anim.length - anim.track_get_key_time(t, k), 0.0),
				anim.track_get_key_value(t, k))
	return out
