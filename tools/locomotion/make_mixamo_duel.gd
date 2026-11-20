extends SceneTree

# Bakes the M1 exchange and the M2 duel's own clips from Mixamo takes
# (tools/locomotion/takes/mixamo_duel.glb, made by mixamo_retarget.py with
# DUEL=1; the walk from takes/mixamo.glb), replacing the Kimodo bakes of
# tools/kimodo/make_exchange_animations.gd and make_duel_animations.gd. It
# writes the same files under the same clip names:
#
#   assets/exchange_animations.tres   Exchange_Hero, Exchange_Attacker
#   assets/paired_clips/exchange.tres the PairedClip that plays them
#   assets/duel_animations.tres       Victim_Cornered, Hero_Drop,
#                                     Attacker_Advance, Hero_After
#
#   godot --headless --path . -s res://tools/locomotion/make_mixamo_duel.gd
#
# The takes (picked from the review reel, tools/duel_mixamo_review.tscn):
#
#   attacker  ss_idle_1, gs_downward_slash, death_back
#   hero      ss_idle_1, thrust_stabbing, ss_idle_1; gs_jump_attack to land
#   victim    victim_terrified
#
# A clip here is takes laid end to end at 30 fps, each crossfading into the
# next over a few frames; each take is turned and moved on the floor so it
# starts where and facing how the one before left the body. Then, as in the
# Kimodo bake: the attacker is placed where its chop misses and the hero's
# thrust reaches its belly, the swords lie along the forearms, the hero's
# wrist turns into the thrust and contact IK puts the point on the target,
# and planted feet are pinned. Posture is Mixamo's own.

const Exchange := preload("res://tools/kimodo/make_exchange_animations.gd")

const DUEL_TAKES := "res://tools/locomotion/takes/mixamo_duel.glb"
const LOCO_TAKES := "res://tools/locomotion/takes/mixamo.glb"
const MALE := "res://scenes/character_models/cc_male_model.tscn"
const FEMALE := "res://scenes/character_models/cc_female_model.tscn"
const OUT_EXCHANGE := "res://assets/exchange_animations.tres"
const OUT_PAIR := "res://assets/paired_clips/exchange.tres"
const OUT_DUEL := "res://assets/duel_animations.tres"
const FPS := 30.0

const IDLE := "ss_idle_1"
const CHOP := "gs_downward_slash"
const THRUST := "thrust_stabbing"
const DEATH := "death_back"
const LEAP := "gs_jump_attack"
const VICTIM := "victim_terrified"
const WALK := "loco_walk"

## Exchange frames (the clip's own clock): the chop bottoms out on MISS,
## the hero's thrust is home on KILL. The same gap as the Kimodo bake's,
## with less standing before it.
const MISS := 36
const KILL := 48
## The thrust is fully out this many frames after the kill, so the arm is
## still bent at contact and the IK has room to reach either way.
const HOME_AFTER := 0
## How much nearer than the arm's full reach the kill's target is put.
const SLACK := 0.05
## Crossfades, in frames.
const FADE := 6
const DEATH_FADE := 2
const SETTLE_FADE := 12
## Frames of the leap kept after the landing, before it fades to the idle.
const LEAP_AFTER := 16
## Frames held on after the body has come to rest.
const REST_PAD := 8
## The scene clock of cinematics/duel_m2.tscn the clips are timed against:
## the hero's landing, and the earliest the exchange may start.
const LAND_AT := 2.4
const EXCHANGE_AT := 2.8333
const VICTIM_FRAMES := 360
const AFTER_FRAMES := 90
const FINGERS := ["Thumb", "Index", "Middle", "Ring", "Little"]

var helper: Object
var _src := {}
var _report: PackedStringArray = []


func _initialize() -> void:
	_bake.call_deferred()


func _bake() -> void:
	await process_frame
	helper = Exchange.new()
	_load(DUEL_TAKES, "")
	_load(LOCO_TAKES, "loco_")
	for need in [IDLE, CHOP, THRUST, DEATH, LEAP, VICTIM, WALK]:
		if not _src.has(need):
			push_error("take missing: %s (have %s)" % [need, _src.keys()])
			quit(1)
			return
	var male = await _body(MALE)
	var female = await _body(FEMALE)
	var stance: Animation = male.player.get_animation(&"Weapon/Stance_Sword")

	var duel := AnimationLibrary.new()
	var drop: Dictionary = _hero_drop(male, stance)
	duel.add_animation(&"Hero_Drop", drop.clip)
	var exchange_at: float = maxf(EXCHANGE_AT, LAND_AT + drop.after_landing)
	_report.append("STAGE: PlaceHero/HeroDrop at %.4f s (landing %.3f s into the clip lands on %.2f); Exchange at %.4f s"
			% [LAND_AT - drop.landing, drop.landing, LAND_AT, exchange_at])

	var ok := _exchange(male, stance)

	duel.add_animation(&"Attacker_Advance", _advance(male, stance, roundi(exchange_at * FPS)))
	duel.add_animation(&"Victim_Cornered", _victim(female))
	duel.add_animation(&"Hero_After", _after(male, stance))
	var err: Error = ResourceSaver.save(duel, OUT_DUEL)
	_report.append("%s: %s" % [OUT_DUEL, error_string(err)])
	for line in _report:
		print(line)
	helper.free()
	quit(0 if ok and err == OK else 1)


# THE EXCHANGE. Both start on the idle's first frame, hips over the origin,
# facing +Z (the attacker is turned and moved by the PairedClip's placement).
func _exchange(b, stance: Animation) -> bool:
	var chop_rows := _rows(b, CHOP, 0, _last(CHOP))
	var bottom := _chop_bottom(chop_rows)
	var thrust_rows := _rows(b, THRUST, 0, _last(THRUST))
	var home := _thrust_home(thrust_rows)
	var death_rows := _rows(b, DEATH, 0, _last(DEATH))
	var onset := _onset(death_rows)
	var settle := _settle(death_rows)
	_report.append("takes: %s bottoms on %d of %d; %s home on %d of %d; %s reacts on %d, at rest on %d of %d"
			% [CHOP, bottom, _last(CHOP), THRUST, home, _last(THRUST), DEATH, onset, settle, _last(DEATH)])

	# Attacker: idle, the chop timed to bottom on MISS, the death from KILL.
	var idle_n: int = MISS + FADE - bottom
	var chop_from := 0
	if idle_n < FADE + 2:
		chop_from = FADE + 2 - idle_n
		idle_n = FADE + 2
	var chop_start: int = idle_n - FADE
	var chop_to: int = chop_from + (KILL + DEATH_FADE) - chop_start - 1
	var length: int = KILL + (settle + REST_PAD - onset) + 1
	var attacker: Animation = _compose([
			[IDLE, 0, idle_n - 1, 0],
			[CHOP, chop_from, chop_to, FADE],
			[DEATH, onset, mini(settle + REST_PAD, _last(DEATH)), DEATH_FADE]], length)
	# Hero: idle, the thrust timed to be home on KILL, back to the idle.
	var lead_n: int = KILL + HOME_AFTER + FADE - home
	var thrust_from := 0
	if lead_n < FADE + 2:
		thrust_from = FADE + 2 - lead_n
		lead_n = FADE + 2
	var hero: Animation = _compose([
			[IDLE, 0, lead_n - 1, 0],
			[THRUST, thrust_from, _last(THRUST), FADE],
			[IDLE, 0, _last(IDLE), SETTLE_FADE]], length)
	for clip in [attacker, hero]:
		_hold_sword(clip, stance)
		_place(b, clip, 0)

	var lead = _clone_body(b)
	var partner = _clone_body(b)
	lead.clip = hero
	partner.clip = attacker
	helper._armed_clip(lead, hero)
	helper._armed_clip(partner, attacker)
	var last: int = length - 1
	lead.frames = helper._sample(lead, lead.clip, last)
	partner.frames = helper._sample(partner, partner.clip, last)

	var fit := _fit(lead, partner)
	var placed: Transform3D = fit.placed
	_report.append("Exchange: attacker at %s, turned %.1f deg; cost %.4f (kill %.4f, miss %.4f, apart %.4f)"
			% [placed.origin, rad_to_deg(placed.basis.get_euler().y) - 180.0, fit.cost, fit.kill, fit.miss, fit.apart])

	var targets: Array[Vector3] = []
	for f in last + 1:
		targets.append(placed * partner.frames[f].target)
	helper._aim(lead, KILL, targets)
	lead.frames = helper._sample(lead, lead.clip, last)
	var before_ik: float = helper._tip(lead.frames[KILL]).distance_to(targets[KILL])
	var moved: Dictionary = helper._close_contact(lead, KILL, targets)
	for pass_i in 3:
		helper._pin_feet(lead)
		helper._pin_feet(partner)
	lead.frames = helper._sample(lead, lead.clip, last)
	partner.frames = helper._sample(partner, partner.clip, last)
	helper._report(lead, partner, placed, MISS, KILL, targets, before_ik, moved)
	_report.append_array(helper._report_lines)
	_report.append("Exchange: %d frames (%.3f s); the attacker is down from frame %d"
			% [length, last / FPS, KILL + settle - onset])

	var library := AnimationLibrary.new()
	library.add_animation(&"Exchange_Hero", lead.clip)
	library.add_animation(&"Exchange_Attacker", partner.clip)
	var err: Error = ResourceSaver.save(library, OUT_EXCHANGE)
	_report.append("%s: %s" % [OUT_EXCHANGE, error_string(err)])

	var pair := PairedClip.new()
	pair.lead_clip = "Exchange/Exchange_Hero"
	pair.partner_clip = "Exchange/Exchange_Attacker"
	pair.partner_from_lead = placed
	var miss := ContactEvent.make(MISS / FPS, ContactEvent.Kind.MISS, Exchange.MISS_STRENGTH)
	miss.striker = ContactEvent.Who.PARTNER
	miss.target_side = ContactEvent.Who.LEAD
	miss.target = &"Head"
	var kill := ContactEvent.make(KILL / FPS, ContactEvent.Kind.KILL, Exchange.KILL_STRENGTH,
			ContactEvent.Cut.AFTER)
	kill.target = StringName(Exchange.TARGET_BONE)
	var events: Array[ContactEvent] = [miss, kill]
	pair.contacts = events
	pair.contact_time = kill.time
	pair.length = last / FPS
	pair.kills_partner = true
	pair.lead_end = helper._travel(lead)
	pair.partner_end = helper._travel(partner)
	var saved: Error = ResourceSaver.save(pair, OUT_PAIR)
	_report.append("%s: %s" % [OUT_PAIR, error_string(saved)])
	lead.model.queue_free()
	partner.model.queue_free()
	return err == OK and saved == OK


# Where the attacker stands, in the hero's space: the thrust's point on its
# belly at KILL, the chop clear of the hero at MISS, bodies apart.
func _fit(lead, partner) -> Dictionary:
	var best := {cost = INF}
	var l: Dictionary = lead.frames[KILL]
	var reach: float = helper._tip(l).distance_to(l.hand) - SLACK
	for turn_deg in range(-45, 46, 5):
		var basis := Basis(Vector3.UP, PI + deg_to_rad(turn_deg))
		for xi in range(-12, 13):
			for zi in range(10, 31):
				var placed := Transform3D(basis, Vector3(xi * 0.08, 0.0, zi * 0.08))
				# The point can reach the target by the wrist's turn alone:
				# the target as far from the hand as the point is (a rigid
				# reach), less SLACK, so the arm bends a little into it (IK
				# can always bend an arm; it cannot lengthen a straight one).
				var off: float = lead.frames[KILL].hand.distance_to(placed * partner.frames[KILL].target) - reach
				var kill: float = 4.0 * off * off + 0.001 * deg_to_rad(turn_deg) ** 2
				if kill >= best.cost:
					continue
				var miss: float = helper._miss_cost(lead, partner, placed, MISS, MISS)
				var apart: float = helper._apart_cost(lead, partner, placed)
				var cost: float = kill + miss + apart
				if cost < best.cost:
					best = {cost = cost, placed = placed, kill = kill, miss = miss, apart = apart}
	return best


# HERO_DROP: the leap, then into the idle, ending on the idle's last frame
# (the exchange starts on its first: the idle loops) over the landing mark.
func _hero_drop(b, stance: Animation) -> Dictionary:
	var tail := 24
	var raw := _landing(_rows(b, LEAP, 0, _last(LEAP)))
	var clip := _compose([
			[LEAP, 0, mini(raw + LEAP_AFTER, _last(LEAP)), 0],
			[IDLE, _last(IDLE) - tail + 1, _last(IDLE), SETTLE_FADE]])
	_hold_sword(clip, stance)
	_place(b, clip, -1)
	b.clip = clip
	var before: Dictionary = _foot_travel(b)
	for pass_i in 3:
		helper._pin_feet(b)
	var rows: Array[Dictionary] = helper._sample(b, b.clip, _frames(clip) - 1)
	var land: int = _landing(rows)
	_note("Hero_Drop", b, before, rows, true)
	_report.append("Hero_Drop: landing on clip frame %d (%.3f s) of %d" % [land, land / FPS, _frames(clip)])
	return {clip = b.clip, landing = land / FPS, after_landing = (_frames(clip) - 1 - land) / FPS}


# ATTACKER_ADVANCE: walking cycles into the idle, `frames` long, ending on
# the idle's last frame over the origin (his place in the exchange).
func _advance(b, stance: Animation, frames: int) -> Animation:
	var tail := 30
	var segs: Array = []
	var cycle: int = _last(WALK)
	var n := 0
	while n < frames + cycle:
		segs.append([WALK, 0, cycle, 1 if not segs.is_empty() else 0])
		n += cycle
	segs.append([IDLE, _last(IDLE) - tail + 1, _last(IDLE), SETTLE_FADE])
	var long := _compose(segs)
	var clip := _tail(long, frames)
	_hold_sword(clip, stance)
	_place(b, clip, -1)
	b.clip = clip
	var before: Dictionary = _foot_travel(b)
	for pass_i in 3:
		helper._pin_feet(b)
	var rows: Array[Dictionary] = helper._sample(b, b.clip, frames - 1)
	_note("Attacker_Advance", b, before, rows, true)
	return b.clip


func _victim(b) -> Animation:
	var to: int = mini(VICTIM_FRAMES, _last(VICTIM))
	var clip := _compose([[VICTIM, 0, to, 0]])
	_place(b, clip, -1)
	b.clip = clip
	var before: Dictionary = _foot_travel(b)
	for pass_i in 3:
		helper._pin_feet(b)
	_note("Victim_Cornered", b, before, helper._sample(b, b.clip, to), true)
	return b.clip


func _after(b, stance: Animation) -> Animation:
	var to: int = mini(AFTER_FRAMES, _last(IDLE))
	var clip := _compose([[IDLE, 0, to, 0]])
	_hold_sword(clip, stance)
	_place(b, clip, 0)
	b.clip = clip
	var before: Dictionary = _foot_travel(b)
	for pass_i in 3:
		helper._pin_feet(b)
	_note("Hero_After", b, before, helper._sample(b, b.clip, to), false)
	return b.clip


# --- takes ---------------------------------------------------------------

func _load(path: String, prefix: String) -> void:
	var scene: Node = (load(path) as PackedScene).instantiate()
	var player: AnimationPlayer = scene.find_children("*", "AnimationPlayer", true, false)[0]
	for lib_name in player.get_animation_library_list():
		var lib := player.get_animation_library(lib_name)
		for anim_name in lib.get_animation_list():
			var anim: Animation = lib.get_animation(anim_name)
			var tracks := {}
			for t in anim.get_track_count():
				var type: Animation.TrackType = anim.track_get_type(t)
				if type != Animation.TYPE_ROTATION_3D and type != Animation.TYPE_POSITION_3D:
					continue
				var bone: String = String(anim.track_get_path(t)).get_slice(":", 1)
				if type == Animation.TYPE_POSITION_3D and bone != "Hips":
					continue
				tracks[[bone, type]] = t
			_src[prefix + String(anim_name)] = {anim = anim, tracks = tracks,
					frames = roundi(anim.length * FPS) + 1}
	scene.free()


func _last(take: String) -> int:
	return _src[take].frames - 1


# One pose of a take: {[bone, type]: value}.
func _pose(take: String, f: int) -> Dictionary:
	var s: Dictionary = _src[take]
	var t: float = clampf(f / FPS, 0.0, s.anim.length)
	var out := {}
	for key: Array in s.tracks:
		var i: int = s.tracks[key]
		if key[1] == Animation.TYPE_ROTATION_3D:
			out[key] = s.anim.rotation_track_interpolate(i, t)
		else:
			out[key] = s.anim.position_track_interpolate(i, t)
	return out


# Takes end to end: segs are [take, from, to, fade]; each one's first
# `fade` frames crossfade over the frames before it. Each is turned about
# Y and moved on the floor so its first frame's hips stand where and face
# how the pose it fades over has them. `length` > 0 cuts or holds the end.
func _compose(segs: Array, length: int = 0) -> Animation:
	var out: Array[Dictionary] = []
	var hips_pos := ["Hips", Animation.TYPE_POSITION_3D]
	var hips_rot := ["Hips", Animation.TYPE_ROTATION_3D]
	for seg: Array in segs:
		var poses: Array[Dictionary] = []
		for f in range(seg[1], seg[2] + 1):
			poses.append(_pose(seg[0], f))
		var overlap: int = mini(seg[3], mini(out.size(), poses.size()))
		var at: int = out.size() - overlap
		if not out.is_empty():
			var anchor: Dictionary = out[maxi(at, 0) if overlap > 0 else out.size() - 1]
			var turn: float = _yaw(anchor[hips_rot]) - _yaw(poses[0][hips_rot])
			var q := Quaternion(Vector3.UP, turn)
			var from: Vector3 = poses[0][hips_pos]
			var to: Vector3 = anchor[hips_pos]
			for p in poses:
				var rel: Vector3 = p[hips_pos] - Vector3(from.x, 0.0, from.z)
				var r: Vector3 = q * Vector3(rel.x, 0.0, rel.z)
				p[hips_pos] = Vector3(to.x + r.x, rel.y, to.z + r.z)
				p[hips_rot] = q * p[hips_rot]
		for i in poses.size():
			if i < overlap:
				var w: float = smoothstep(0.0, 1.0, float(i + 1) / float(overlap + 1))
				out[at + i] = _blend(out[at + i], poses[i], w)
			else:
				out.append(poses[i])
	if length > 0:
		while out.size() < length:
			out.append(out[-1])
		out.resize(length)
	return _animation(out)


func _blend(a: Dictionary, b: Dictionary, w: float) -> Dictionary:
	var out := {}
	for key: Array in a:
		if not b.has(key):
			out[key] = a[key]
		elif key[1] == Animation.TYPE_ROTATION_3D:
			out[key] = (a[key] as Quaternion).slerp(b[key], w)
		else:
			out[key] = (a[key] as Vector3).lerp(b[key], w)
	return out


# Heading of a hips rotation: its Z axis on the floor.
func _yaw(q: Quaternion) -> float:
	var z: Vector3 = Basis(q) * Vector3.FORWARD * -1.0
	return atan2(z.x, z.z)


func _animation(poses: Array[Dictionary]) -> Animation:
	var anim := Animation.new()
	anim.length = (poses.size() - 1) / FPS
	for key: Array in poses[0]:
		var t: int = anim.add_track(key[1])
		anim.track_set_path(t, NodePath("%GeneralSkeleton:" + key[0]))
		for f in poses.size():
			if key[1] == Animation.TYPE_ROTATION_3D:
				anim.rotation_track_insert_key(t, f / FPS, poses[f][key])
			else:
				anim.position_track_insert_key(t, f / FPS, poses[f][key])
	return anim


func _frames(clip: Animation) -> int:
	return roundi(clip.length * FPS) + 1


# The last `frames` frames of a clip.
func _tail(clip: Animation, frames: int) -> Animation:
	var total: int = _frames(clip)
	var skip: int = maxi(0, total - frames)
	var out := Animation.new()
	out.length = (frames - 1) / FPS
	for i in clip.get_track_count():
		var type: Animation.TrackType = clip.track_get_type(i)
		var t: int = out.add_track(type)
		out.track_set_path(t, clip.track_get_path(i))
		for f in frames:
			var v = clip.track_get_key_value(i, mini(f + skip, total - 1))
			if type == Animation.TYPE_ROTATION_3D:
				out.rotation_track_insert_key(t, f / FPS, v)
			else:
				out.position_track_insert_key(t, f / FPS, v)
	return out


# The right hand's fingers closed on the grip, as Weapon/Stance_Sword has them.
func _hold_sword(clip: Animation, stance: Animation) -> void:
	for i in stance.get_track_count():
		if stance.track_get_type(i) != Animation.TYPE_ROTATION_3D:
			continue
		var bone: String = String(stance.track_get_path(i)).get_slice(":", 1)
		if not bone.begins_with("Right") or not FINGERS.any(func(n: String) -> bool: return bone.contains(n)):
			continue
		var q: Quaternion = stance.track_get_key_value(i, 0)
		var t: int = clip.find_track(NodePath("%GeneralSkeleton:" + bone), Animation.TYPE_ROTATION_3D)
		if t < 0:
			t = clip.add_track(Animation.TYPE_ROTATION_3D)
			clip.track_set_path(t, NodePath("%GeneralSkeleton:" + bone))
			for f in _frames(clip):
				clip.rotation_track_insert_key(t, f / FPS, q)
			continue
		for k in clip.track_get_key_count(t):
			clip.track_set_key_value(t, k, q)


# Turns and moves the whole clip on the floor so frame `anchor` (-1: the
# last) has its hips over the origin, heading as the idle's first frame.
func _place(b, clip: Animation, anchor: int) -> void:
	var f: int = anchor if anchor >= 0 else _frames(clip) - 1
	var pos: int = clip.find_track(NodePath("%GeneralSkeleton:Hips"), Animation.TYPE_POSITION_3D)
	var rot: int = clip.find_track(NodePath("%GeneralSkeleton:Hips"), Animation.TYPE_ROTATION_3D)
	var want: float = _yaw(_pose(IDLE, 0)[["Hips", Animation.TYPE_ROTATION_3D]])
	var q := Quaternion(Vector3.UP, want - _yaw(clip.track_get_key_value(rot, f)))
	var at: Vector3 = clip.track_get_key_value(pos, f)
	for k in clip.track_get_key_count(pos):
		var p: Vector3 = clip.track_get_key_value(pos, k)
		var r: Vector3 = q * Vector3(p.x - at.x, 0.0, p.z - at.z)
		clip.track_set_key_value(pos, k, Vector3(r.x, p.y, r.z))
		clip.track_set_key_value(rot, k, q * (clip.track_get_key_value(rot, k) as Quaternion))
	# Stored hips are skeleton-local over motion_scale; check where the body
	# stands in the world and take out what is left.
	var rows: Array[Dictionary] = helper._sample(b, clip, f)
	var world: Vector3 = rows[f].hips
	var sk: Transform3D = b.skeleton.global_transform
	var off: Vector3 = sk.basis.inverse() * Vector3(world.x - sk.origin.x, 0.0, world.z - sk.origin.z)
	off /= b.skeleton.motion_scale
	for k in clip.track_get_key_count(pos):
		var p: Vector3 = clip.track_get_key_value(pos, k)
		clip.track_set_key_value(pos, k, Vector3(p.x - off.x, p.y, p.z - off.z))


# --- measures ------------------------------------------------------------

func _rows(b, take: String, from: int, to: int) -> Array[Dictionary]:
	return helper._sample(b, _compose([[take, from, to, 0]]), to - from)


# The chop's bottom: the lowest the hand comes after its highest.
func _chop_bottom(rows: Array[Dictionary]) -> int:
	var top := 0
	for f in rows.size():
		if rows[f].hand.y > rows[top].hand.y:
			top = f
	var low := top
	for f in range(top, rows.size()):
		if rows[f].hand.y < rows[low].hand.y:
			low = f
	return low


# The thrust home: the hand farthest in front of the hips.
func _thrust_home(rows: Array[Dictionary]) -> int:
	var best := 0
	for f in rows.size():
		if rows[f].hand.z - rows[f].hips.z > rows[best].hand.z - rows[best].hips.z:
			best = f
	return best


# The reaction's first frame: the hips have moved 2 cm from the take's start.
func _onset(rows: Array[Dictionary]) -> int:
	for f in rows.size():
		if rows[f].hips.distance_to(rows[0].hips) > 0.02:
			return maxi(0, f - 2)
	return 0


# At rest: from here on the hips move under 1 cm a frame.
func _settle(rows: Array[Dictionary]) -> int:
	for f in range(rows.size() - 1, 0, -1):
		if rows[f].hips.distance_to(rows[f - 1].hips) > 0.01:
			return f
	return 0


func _landing(rows: Array[Dictionary]) -> int:
	const AIRBORNE := 0.12
	const STOPPED := 0.01
	var floor_y := INF
	for row in rows:
		for k in ["LeftFoot", "LeftToes", "RightFoot", "RightToes"]:
			floor_y = minf(floor_y, row[k].y)
	var flying := false
	for f in rows.size() - 1:
		var left: float = minf(rows[f].LeftFoot.y, rows[f].LeftToes.y) - floor_y
		var right: float = minf(rows[f].RightFoot.y, rows[f].RightToes.y) - floor_y
		if left > AIRBORNE and right > AIRBORNE:
			flying = true
			continue
		if not flying:
			continue
		for side in ["Left", "Right"]:
			var now: float = minf(rows[f][side + "Foot"].y, rows[f][side + "Toes"].y)
			var next: float = minf(rows[f + 1][side + "Foot"].y, rows[f + 1][side + "Toes"].y)
			if now - floor_y < AIRBORNE and now - next < STOPPED:
				return f
	return -1


func _foot_travel(b) -> Dictionary:
	var rows: Array[Dictionary] = helper._sample(b, b.clip, _frames(b.clip) - 1)
	var out := {}
	for side in ["Left", "Right"]:
		var worst := 0.0
		for run: Vector2i in helper._plants(rows, side):
			for f in range(run.x, run.y + 1):
				var d: Vector3 = rows[f][side + "Foot"] - rows[run.x][side + "Foot"]
				worst = maxf(worst, Vector2(d.x, d.z).length())
		out[side] = worst
	return out


func _note(name: String, b, before: Dictionary, rows: Array[Dictionary], by_end: bool) -> void:
	var after: Dictionary = _foot_travel(b)
	var hips: Vector3 = rows[-1].hips if by_end else rows[0].hips
	_report.append("%s: %d frames (%.2f s); hips %s %s; planted-foot travel worst L %.4f R %.4f m (before pins %.4f / %.4f)"
			% [name, _frames(b.clip), b.clip.length, "end" if by_end else "start",
			Vector3(hips.x, 0.0, hips.z), after.Left, after.Right, before.Left, before.Right])


# --- bodies --------------------------------------------------------------

func _body(scene: String):
	var b = Exchange.Body.new()
	b.model = (load(scene) as PackedScene).instantiate()
	root.add_child(b.model)
	await process_frame
	await process_frame
	b.skeleton = b.model.find_child("GeneralSkeleton", true, false)
	b.player = b.model.get_node("Body/AnimationPlayer")
	b.grip = b.model.get("main_hand_grip")
	return b


func _clone_body(b):
	var c = Exchange.Body.new()
	c.model = b.model
	c.skeleton = b.skeleton
	c.player = b.player
	c.grip = b.grip
	return c
