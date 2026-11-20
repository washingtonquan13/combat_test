extends SceneTree

# Generates assets/exchange_animations.tres (the "Exchange" library on the
# CC bodies) and assets/paired_clips/exchange.tres, the PairedClip that
# plays it.
#
#   godot --headless --path . -s res://tools/kimodo/make_exchange_animations.gd
#
# The exchange (docs/plans/bg3_cinematics.md, M1): the attacker winds up and
# brings an overhead chop down; the hero sidesteps it, so it misses, and
# answers with a lunge that runs the attacker through the belly.
#
#   Exchange_Hero       the hero's half (lead), baked on the male CC body
#   Exchange_Attacker   the attacker's half (partner), on the male CC body
#
# Each half is one Kimodo take (tools/kimodo/takes/exchange_hero and
# exchange_attacker, with the text and constraints that made them), picked
# from several seeds by tools/kimodo/score_take.py. Posture is the take's
# own. What is done here, and nothing else:
#
#   Where they stand. The attacker is placed where its chop lands close to
#   the hero but clear of them, and the hero's thrust reaches its belly.
#   The same clock. The attacker's take is retimed, piecewise, so its chop
#   and its being struck land on the hero's frames for them.
#   The blades. A sword along each right forearm; around the kill the
#   hero's wrist turns so the blade points through the target.
#   Contact IK. The hero's arm is bent (two-bone IK) so the point reaches
#   the target exactly: in over IK_IN frames, out over IK_OUT, never moving
#   the hand more than IK_MAX. Planted feet are pinned (two-bone leg IK)
#   so they do not slide. Both are allowed by the plan; nothing else is.
#
# The numbers it prints are M1's exit criteria.

const Retarget := preload("res://tools/kimodo/soma_retarget.gd")

const OUT := "res://assets/exchange_animations.tres"
const PAIR := "res://assets/paired_clips/exchange.tres"
const LEAD_MODEL := "res://scenes/character_models/cc_male_model.tscn"
const PARTNER_MODEL := "res://scenes/character_models/cc_male_model.tscn"
const TAKES := "res://tools/kimodo/takes/"
const LEAD_TAKE := "exchange_hero"
const PARTNER_TAKE := "exchange_attacker"

const BLADE := 0.787
## Take frame both clips start on (some stance before anything moves).
const START := 20
## The hero's take frame the clip ends on.
const LEAD_LAST := 125
## Take frames. miss: the attacker's chop bottoms out (partner) while the
## hero (lead) is clear. kill: the hero's point in the attacker's belly.
## The search looks SEARCH frames either side on the attacker's take.
const MISS := {lead = 72, partner = 74}
const KILL := {lead = 84, partner = 86}
const SEARCH := 4
## The kill is searched closer: the attacker's take starts recoiling on its
## KILL frame, and the reaction may not lead the blade (spec 5.1: it
## starts within a frame of the contact).
const KILL_SEARCH := 1
## The bone the point goes into, and how deep past it the point is aimed
## (along the thrust): Spine sits at the middle of the belly.
const TARGET_BONE := "Spine"
const MISS_STRENGTH := 0.0
const KILL_STRENGTH := 1.0
## Closest the two bodies' middles may come.
const APART := 0.8
## How close the miss may pass: between these, measured from the blade to
## the hero's body (a capsule from hips to head of BODY_RADIUS).
const CLEAR_MIN := 0.12
const CLEAR_MAX := 0.40
const BODY_RADIUS := 0.16
## The frames around the miss the blade is checked over: the whole
## downswing and the moment after it.
const MISS_BEFORE := 12
const MISS_AFTER := 4
## Contact IK windows (spec 5.1: in over 4 to 6, out over 6 to 10 frames,
## at most 15 cm), and the frames it holds on the target after contact.
const IK_IN := 5
const IK_HOLD := 4
const IK_OUT := 8
const IK_MAX := 0.15
## The wrist turns into the thrust over this many frames.
const AIM_IN := 6
## A planted foot (the same test as score_take.py): within PLANT_HEIGHT of
## the floor and slower than PLANT_SPEED, for PLANT_MIN frames or more.
const PLANT_HEIGHT := 0.04
const PLANT_SPEED := 0.25
const PLANT_MIN := 3
## Frames a pin takes to come on and let go outside its plant.
const PIN_EASE := 3

var _report_lines: PackedStringArray = []


class Body:
	var model: Node3D
	var skeleton: Skeleton3D
	var player: AnimationPlayer
	var grip: Node3D
	var take: Retarget
	var clip: Animation
	var frames: Array[Dictionary] = []


func _initialize() -> void:
	_bake.call_deferred()


func _bake() -> void:
	await process_frame
	var lead := _body(LEAD_MODEL, LEAD_TAKE)
	var partner := _body(PARTNER_MODEL, PARTNER_TAKE)
	await process_frame
	await process_frame
	if lead == null or partner == null:
		quit(1)
		return
	var last: int = LEAD_LAST - START
	lead.clip = _base(lead, LEAD_LAST)
	var full: Animation = _base(partner, partner.take.frames - 1)
	_armed(lead)
	_armed_clip(partner, full)
	lead.frames = _sample(lead, lead.clip, last)
	partner.frames = _sample(partner, full, partner.take.frames - 1 - START)

	var fit: Dictionary = _fit(lead, partner)
	var placed: Transform3D = fit.placed
	print("Exchange: attacker at %s, turned %.1f deg; cost %.4f; miss on its frame %d, kill on %d"
			% [placed.origin, rad_to_deg(placed.basis.get_euler().y) - 180.0, fit.cost, fit.miss, fit.kill])

	var lm: int = MISS.lead - START
	var lk: int = KILL.lead - START
	var map: Array[Vector2] = [Vector2.ZERO, Vector2(lm, fit.miss), Vector2(lk, fit.kill)]
	var tail: float = fit.kill + (last - lk)
	map.append(Vector2(last, minf(tail, partner.frames.size() - 1)))
	print("Exchange: attacker's clock (hero frame, attacker frame): %s" % [map])
	partner.clip = _retimed(full, map, last)
	partner.frames = _sample(partner, partner.clip, last)

	# The kill: the target, per frame, in the hero's space.
	var targets: Array[Vector3] = []
	for f in last + 1:
		targets.append(placed * partner.frames[f].target)
	_aim(lead, lk, targets)
	lead.frames = _sample(lead, lead.clip, last)
	var before_ik: float = _tip(lead.frames[lk]).distance_to(targets[lk])
	var moved: Dictionary = _close_contact(lead, lk, targets)
	# Twice: a pin's easing can make the frames beside a plant read as part
	# of it, so the second pass pins the plants the pinned clip has.
	for pass_i in 2:
		_pin_feet(lead)
		_pin_feet(partner)
	lead.frames = _sample(lead, lead.clip, last)
	partner.frames = _sample(partner, partner.clip, last)

	_report(lead, partner, placed, lm, lk, targets, before_ik, moved)

	var library := AnimationLibrary.new()
	library.add_animation(&"Exchange_Hero", lead.clip)
	library.add_animation(&"Exchange_Attacker", partner.clip)
	var err: Error = ResourceSaver.save(library, OUT)
	print("%s: %s" % [OUT, error_string(err)])

	var pair := PairedClip.new()
	pair.lead_clip = "Exchange/Exchange_Hero"
	pair.partner_clip = "Exchange/Exchange_Attacker"
	pair.partner_from_lead = placed
	var miss := ContactEvent.make(lm / Retarget.FPS, ContactEvent.Kind.MISS, MISS_STRENGTH)
	miss.striker = ContactEvent.Who.PARTNER
	miss.target_side = ContactEvent.Who.LEAD
	miss.target = &"Head"
	var kill := ContactEvent.make(lk / Retarget.FPS, ContactEvent.Kind.KILL, KILL_STRENGTH,
			ContactEvent.Cut.AFTER)
	kill.target = StringName(TARGET_BONE)
	var events: Array[ContactEvent] = [miss, kill]
	pair.contacts = events
	pair.contact_time = kill.time
	pair.length = last / Retarget.FPS
	pair.kills_partner = true
	pair.lead_end = _travel(lead)
	pair.partner_end = _travel(partner)
	var saved: Error = ResourceSaver.save(pair, PAIR)
	print("%s: %s" % [PAIR, error_string(saved)])
	for line in _report_lines:
		print(line)
	quit(0 if err == OK and saved == OK else 1)


func _body(scene: String, take_name: String) -> Body:
	var b := Body.new()
	b.model = (load(scene) as PackedScene).instantiate()
	root.add_child(b.model)
	b.skeleton = b.model.find_child("GeneralSkeleton", true, false)
	b.player = b.model.get_node("Body/AnimationPlayer")
	b.grip = b.model.get("main_hand_grip")
	b.take = Retarget.new()
	if not b.take.read(TAKES + take_name):
		push_error("take missing: %s" % take_name)
		return null
	return b


func _base(b: Body, to: int) -> Animation:
	var squared: Transform3D = b.take.squared(0)
	var at: Vector3 = squared * b.take.world(START)[0].origin
	var placed := Transform3D(squared.basis, squared.origin - Vector3(at.x, 0.0, at.z))
	var fingers: Animation = b.player.get_animation(&"Weapon/Stance_Sword")
	return b.take.animation(b.skeleton, START, to, placed, fingers)


# Per frame, in the body's own space.
func _sample(b: Body, clip: Animation, last: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	_show(b, clip)
	var bones := {}
	for name in ["Hips", "Head", "RightHand", TARGET_BONE, "LeftFoot", "LeftToes", "RightFoot", "RightToes"]:
		bones[name] = b.skeleton.find_bone(name)
	for f in last + 1:
		b.player.seek(f / Retarget.FPS, true)
		b.player.advance(0.0)
		var sk: Transform3D = b.skeleton.global_transform
		var hand: Transform3D = sk * b.skeleton.get_bone_global_pose(bones.RightHand)
		var grip: Transform3D = hand * b.grip.transform
		var row := {
			hips = (sk * b.skeleton.get_bone_global_pose(bones.Hips)).origin,
			head = (sk * b.skeleton.get_bone_global_pose(bones.Head)).origin,
			hand = hand.origin,
			grip = grip.origin,
			blade = grip.basis.y.normalized(),
			target = (sk * b.skeleton.get_bone_global_pose(bones[TARGET_BONE])).origin,
		}
		for name in ["LeftFoot", "LeftToes", "RightFoot", "RightToes"]:
			row[name] = (sk * b.skeleton.get_bone_global_pose(bones[name])).origin
		out.append(row)
	_hide(b)
	return out


func _tip(row: Dictionary) -> Vector3:
	return row.grip + row.blade * BLADE


# Where the attacker stands (hero's space) and the attacker frames the miss
# and the kill land on.
func _fit(lead: Body, partner: Body) -> Dictionary:
	var best := {cost = INF}
	var lm: int = MISS.lead - START
	var lk: int = KILL.lead - START
	for turn_deg in range(-30, 31, 5):
		var basis := Basis(Vector3.UP, PI + deg_to_rad(turn_deg))
		for xi in range(-12, 13):
			for zi in range(10, 31):
				var placed := Transform3D(basis, Vector3(xi * 0.08, 0.0, zi * 0.08))
				var kill := _best(partner, KILL.partner, func(fp: int) -> float:
					return _kill_cost(lead.frames[lk], partner.frames[fp], placed), KILL_SEARCH)
				if kill.cost >= best.cost:
					continue
				var miss := _best(partner, MISS.partner, func(fp: int) -> float:
					return _miss_cost(lead, partner, placed, lm, fp))
				var cost: float = kill.cost + miss.cost + _apart_cost(lead, partner, placed)
				if cost < best.cost:
					best = {cost = cost, placed = placed, kill = kill.frame, miss = miss.frame}
	return best


func _best(partner: Body, around: int, cost_of: Callable, search: int = SEARCH) -> Dictionary:
	var pick := {cost = INF, frame = around - START}
	for fp in range(around - START - search, around - START + search + 1):
		if fp < 0 or fp >= partner.frames.size():
			continue
		var c: float = cost_of.call(fp)
		if c < pick.cost:
			pick = {cost = c, frame = fp}
	return pick


func _kill_cost(l: Dictionary, p: Dictionary, placed: Transform3D) -> float:
	# The point reaches the target: grip to target about a blade's length.
	var off: float = l.grip.distance_to(placed * p.target) - BLADE
	return 4.0 * off * off


func _miss_cost(lead: Body, partner: Body, placed: Transform3D, lm: int, fp: int) -> float:
	var clear: float = INF
	for d in range(-MISS_BEFORE, MISS_AFTER + 1):
		var fl: int = clampi(lm + d, 0, lead.frames.size() - 1)
		var fa: int = clampi(fp + d, 0, partner.frames.size() - 1)
		clear = minf(clear, _clearance(lead.frames[fl], partner.frames[fa], placed))
	return 50.0 * pow(maxf(0.0, CLEAR_MIN - clear), 2) + pow(maxf(0.0, clear - CLEAR_MAX), 2)


# From the attacker's blade to the hero's body, a capsule hips to head.
func _clearance(l: Dictionary, p: Dictionary, placed: Transform3D) -> float:
	var a: Vector3 = placed * p.grip
	var b: Vector3 = placed * _tip(p)
	return _segments(a, b, l.hips, l.head) - BODY_RADIUS


func _apart_cost(lead: Body, partner: Body, placed: Transform3D) -> float:
	var cost := 0.0
	for f in range(0, lead.frames.size(), 4):
		var fa: int = mini(f, partner.frames.size() - 1)
		var d: Vector3 = placed * partner.frames[fa].hips - lead.frames[f].hips
		d.y = 0.0
		cost += 4.0 * pow(maxf(0.0, APART - d.length()), 2)
	return cost


func _retimed(src: Animation, map: Array[Vector2], last: int) -> Animation:
	var out := Animation.new()
	out.length = last / Retarget.FPS
	for i in src.get_track_count():
		var type: Animation.TrackType = src.track_get_type(i)
		var t: int = out.add_track(type)
		out.track_set_path(t, src.track_get_path(i))
		if src.track_get_key_count(i) <= 1:
			for k in src.track_get_key_count(i):
				if type == Animation.TYPE_ROTATION_3D:
					out.rotation_track_insert_key(t, 0.0, src.track_get_key_value(i, k))
				else:
					out.track_insert_key(t, 0.0, src.track_get_key_value(i, k))
			continue
		for f in last + 1:
			var at: float = _clock(map, f) / Retarget.FPS
			if type == Animation.TYPE_POSITION_3D:
				out.position_track_insert_key(t, f / Retarget.FPS, src.position_track_interpolate(i, at))
			elif type == Animation.TYPE_ROTATION_3D:
				out.rotation_track_insert_key(t, f / Retarget.FPS, src.rotation_track_interpolate(i, at))
	return out


func _clock(map: Array[Vector2], f: float) -> float:
	for i in range(1, map.size()):
		if f <= map[i].x:
			return lerpf(map[i - 1].y, map[i].y, (f - map[i - 1].x) / (map[i].x - map[i - 1].x))
	return map[-1].y


# The right wrist turned on every frame so the sword lies along the forearm.
func _armed(b: Body) -> void:
	_armed_clip(b, b.clip)


func _armed_clip(b: Body, clip: Animation) -> void:
	var keep: Animation = b.clip
	b.clip = clip
	_turn_wrist(b, func(_f: int, forearm: Transform3D, wrist: Transform3D, _blade: Vector3) -> Dictionary:
		return {dir = (wrist.origin - forearm.origin).normalized(), weight = 1.0})
	b.clip = keep if keep != null else clip


# Around frame `on`, the blade turned to point through the target.
func _aim(b: Body, on: int, targets: Array[Vector3]) -> void:
	var inv: Transform3D = b.skeleton.global_transform.affine_inverse()
	_turn_wrist(b, func(f: int, _forearm: Transform3D, wrist: Transform3D, _blade: Vector3) -> Dictionary:
		var w: float = _window(f, on, AIM_IN, IK_HOLD, IK_OUT)
		if w <= 0.0:
			return {dir = Vector3.ZERO, weight = 0.0}
		var grip: Vector3 = wrist * b.grip.transform.origin
		var at: Vector3 = inv * targets[clampi(f, 0, targets.size() - 1)]
		return {dir = (at - grip).normalized(), weight = w})


func _window(f: int, on: int, into: int, hold: int, out: int) -> float:
	if f < on:
		return smoothstep(float(on - into), float(on), float(f))
	if f <= on + hold:
		return 1.0
	return 1.0 - smoothstep(float(on + hold), float(on + hold + out), float(f))


func _turn_wrist(b: Body, want: Callable) -> void:
	var hand: int = b.skeleton.find_bone("RightHand")
	var forearm: int = b.skeleton.find_bone("RightLowerArm")
	var track: int = b.clip.find_track(NodePath("%GeneralSkeleton:RightHand"), Animation.TYPE_ROTATION_3D)
	var keys: Array[Quaternion] = []
	_show(b, b.clip)
	for key in b.clip.track_get_key_count(track):
		var time: float = b.clip.track_get_key_time(track, key)
		b.player.seek(time, true)
		b.player.advance(0.0)
		var arm: Transform3D = b.skeleton.get_bone_global_pose(forearm)
		var wrist: Transform3D = b.skeleton.get_bone_global_pose(hand)
		var blade: Vector3 = (wrist.basis * b.grip.transform.basis.y).normalized()
		var w: Dictionary = want.call(roundi(time * Retarget.FPS), arm, wrist, blade)
		var now: Quaternion = b.clip.track_get_key_value(track, key)
		if w.weight <= 0.0:
			keys.append(now)
			continue
		var turned: Basis = Basis(Quaternion(blade, w.dir)) * wrist.basis.orthonormalized()
		var local: Quaternion = (arm.basis.orthonormalized().inverse() * turned).get_rotation_quaternion()
		keys.append(now.slerp(local, w.weight))
	_hide(b)
	for key in keys.size():
		b.clip.track_set_key_value(track, key, keys[key])


# CONTACT IK. On the frames around the kill, the hero's arm bends so the
# blade's point lands on the target; the wrist keeps its turn (so the
# blade's direction), and the hand is moved by the point's miss, weighted
# by the window. Returns the largest hand move and the window's frames.
func _close_contact(b: Body, on: int, targets: Array[Vector3]) -> Dictionary:
	var inv: Transform3D = b.skeleton.global_transform.affine_inverse()
	var chain: Array[int] = [b.skeleton.find_bone("RightUpperArm"),
			b.skeleton.find_bone("RightLowerArm"), b.skeleton.find_bone("RightHand")]
	var largest := 0.0
	var first := -1
	var last_on := -1
	var wanted := {}
	_show(b, b.clip)
	for f in range(on - IK_IN, on + IK_HOLD + IK_OUT + 1):
		var w: float = _window(f, on, IK_IN, IK_HOLD, IK_OUT)
		if w <= 0.0 or f < 0 or f >= targets.size():
			continue
		if first < 0:
			first = f
		last_on = f
		_seek(b, f)
		var wrist: Transform3D = b.skeleton.get_bone_global_pose(chain[2])
		var grip: Transform3D = wrist * b.grip.transform
		var tip: Vector3 = grip.origin + grip.basis.y.normalized() * BLADE
		var miss: Vector3 = (inv * targets[f]) - tip
		var move: Vector3 = miss * w
		if move.length() > IK_MAX:
			move = move.normalized() * IK_MAX
		largest = maxf(largest, move.length())
		wanted[f] = _two_bone(b.skeleton, chain, wrist.origin + move)
	_hide(b)
	_write(b, chain, wanted)
	return {largest = largest, first = first, last = last_on}


# FOOT PINS. Every plant (the score_take.py test) holds its foot where it
# stands at the plant's first frame, the pin easing on and off over
# PIN_EASE frames outside it.
func _pin_feet(b: Body) -> void:
	var count: int = roundi(b.clip.length * Retarget.FPS) + 1
	var rows: Array[Dictionary] = _sample(b, b.clip, count - 1)
	for side in ["Left", "Right"]:
		var chain: Array[int] = [b.skeleton.find_bone(side + "UpperLeg"),
				b.skeleton.find_bone(side + "LowerLeg"), b.skeleton.find_bone(side + "Foot")]
		var runs: Array[Vector2i] = _plants(rows, side)
		if OS.has_environment("EXCHANGE_DEBUG"):
			for run in runs:
				var t := 0.0
				for f in range(run.x, run.y + 1):
					var d: Vector3 = rows[f][side + "Foot"] - rows[run.x][side + "Foot"]
					t = maxf(t, Vector2(d.x, d.z).length())
				print("  pin %s %s %s travel before %.4f" % [b.model.name, side, run, t])
		var weight: PackedFloat32Array = PackedFloat32Array()
		weight.resize(count)
		var spot: Array[Vector3] = []
		spot.resize(count)
		for run in runs:
			var mid: Vector3 = rows[run.x][side + "Foot"]
			for f in range(run.x - PIN_EASE, run.y + PIN_EASE + 1):
				if f < 0 or f >= count:
					continue
				var w := 1.0
				if f < run.x:
					w = float(f - (run.x - PIN_EASE - 1)) / float(PIN_EASE + 1)
				elif f > run.y:
					w = float(run.y + PIN_EASE + 1 - f) / float(PIN_EASE + 1)
				if w > weight[f]:
					weight[f] = w
					spot[f] = mid
		var inv: Transform3D = b.skeleton.global_transform.affine_inverse()
		var wanted := {}
		_show(b, b.clip)
		for f in count:
			if weight[f] <= 0.0:
				continue
			_seek(b, f)
			var foot: Vector3 = b.skeleton.get_bone_global_pose(chain[2]).origin
			var want: Vector3 = foot.lerp(inv * spot[f], smoothstep(0.0, 1.0, weight[f]))
			wanted[f] = _two_bone(b.skeleton, chain, want)
		_hide(b)
		_write(b, chain, wanted)


# Plants of one foot: [first, last] frame runs.
func _plants(rows: Array[Dictionary], side: String) -> Array[Vector2i]:
	var floor_y := INF
	for row in rows:
		floor_y = minf(floor_y, minf(row[side + "Foot"].y, row[side + "Toes"].y))
	var runs: Array[Vector2i] = []
	var start := -1
	for f in rows.size() + 1:
		var down := false
		if f < rows.size():
			var low: float = minf(rows[f][side + "Foot"].y, rows[f][side + "Toes"].y) - floor_y
			var speed := 0.0
			if f > 0:
				var a: Vector3 = rows[f][side + "Foot"]
				var p: Vector3 = rows[f - 1][side + "Foot"]
				speed = Vector2(a.x - p.x, a.z - p.z).length() * Retarget.FPS
			down = low < PLANT_HEIGHT and speed < PLANT_SPEED
		if down and start < 0:
			start = f
		elif not down and start >= 0:
			if f - start >= PLANT_MIN:
				runs.append(Vector2i(start, f - 1))
			start = -1
	return runs


# Two-bone IK (skeleton space): the upper and lower bone turned so the end
# bone's origin reaches `target`, bending in the plane it already bends in;
# the end bone keeps its global turn. Returns the three local rotations.
func _two_bone(sk: Skeleton3D, chain: Array[int], target: Vector3) -> Array[Quaternion]:
	var ga: Transform3D = sk.get_bone_global_pose(chain[0])
	var gb: Transform3D = sk.get_bone_global_pose(chain[1])
	var gc: Transform3D = sk.get_bone_global_pose(chain[2])
	var a: Vector3 = ga.origin
	var b: Vector3 = gb.origin
	var c: Vector3 = gc.origin
	var lab: float = a.distance_to(b)
	var lbc: float = b.distance_to(c)
	var lat: float = clampf(a.distance_to(target), absf(lab - lbc) + 0.001, lab + lbc - 0.001)
	var aim: Vector3 = (target - a).normalized()
	# The elbow (knee) stays on the side of the reach it is already on.
	var pole: Vector3 = (b - a) - aim * aim.dot(b - a)
	if pole.length() < 1e-5:
		pole = aim.cross(ga.basis.x)
	pole = pole.normalized()
	var at_a: float = acos(clampf((lab * lab + lat * lat - lbc * lbc) / (2.0 * lab * lat), -1.0, 1.0))
	var elbow: Vector3 = a + lab * (cos(at_a) * aim + sin(at_a) * pole)
	var end: Vector3 = a + aim * lat
	var qa := Quaternion((b - a).normalized(), (elbow - a).normalized())
	var lower: Vector3 = (qa * (c - b)).normalized()
	var qb := Quaternion(lower, (end - elbow).normalized())
	var new_a: Basis = Basis(qa) * ga.basis.orthonormalized()
	var new_b: Basis = Basis(qb * qa) * gb.basis.orthonormalized()
	var parent: int = sk.get_bone_parent(chain[0])
	var gp: Basis = sk.get_bone_global_pose(parent).basis.orthonormalized() if parent >= 0 else Basis.IDENTITY
	return [
		(gp.inverse() * new_a).get_rotation_quaternion(),
		(new_a.inverse() * new_b).get_rotation_quaternion(),
		(new_b.inverse() * gc.basis.orthonormalized()).get_rotation_quaternion(),
	]


# Puts IK results ({frame: [three local rotations]}) into the chain's keys.
func _write(b: Body, chain: Array[int], wanted: Dictionary) -> void:
	for i in 3:
		var path := NodePath("%GeneralSkeleton:" + b.skeleton.get_bone_name(chain[i]))
		var track: int = b.clip.find_track(path, Animation.TYPE_ROTATION_3D)
		for f: int in wanted:
			b.clip.track_set_key_value(track, f, wanted[f][i])


func _seek(b: Body, f: int) -> void:
	b.player.seek(f / Retarget.FPS, true)
	b.player.advance(0.0)


func _travel(b: Body) -> Transform3D:
	var moved: Vector3 = b.frames[-1].hips - b.frames[0].hips
	return Transform3D(Basis.IDENTITY, Vector3(moved.x, 0.0, moved.z))


func _report(lead: Body, partner: Body, placed: Transform3D, lm: int, lk: int,
		targets: Array[Vector3], before_ik: float, moved: Dictionary) -> void:
	var r := _report_lines
	r.append("M1 EXCHANGE MEASURES")
	var closest := INF
	for f in lead.frames.size():
		var d: Vector3 = placed * partner.frames[f].hips - lead.frames[f].hips
		d.y = 0.0
		closest = minf(closest, d.length())
	r.append("  bodies' middles closest: %.2f m" % closest)
	var clear := INF
	var clear_at := -1
	for f in range(lm - MISS_BEFORE, lm + MISS_AFTER + 1):
		var c: float = _clearance(lead.frames[f], partner.frames[f], placed)
		if c < clear:
			clear = c
			clear_at = f
	r.append("  miss: chop bottoms on frame %d; blade clears the hero's body by %.3f m (closest, frame %d)"
			% [lm, clear, clear_at])
	var contact: float = _tip(lead.frames[lk]).distance_to(targets[lk])
	r.append("  kill frame %d: point to %s %.4f m before IK, %.4f m after (spec <= 0.03, <= 0.01 close)"
			% [lk, TARGET_BONE, before_ik, contact])
	var worst_hold := 0.0
	for f in range(lk, lk + IK_HOLD + 1):
		worst_hold = maxf(worst_hold, _tip(lead.frames[f]).distance_to(targets[f]))
	r.append("  point stays on the target through the hold (frames %d..%d): worst %.4f m"
			% [lk, lk + IK_HOLD, worst_hold])
	r.append("  contact IK: frames %d..%d, in over %d, out over %d, largest hand move %.3f m (spec <= 0.15)"
			% [moved.first, moved.last, IK_IN, IK_OUT, moved.largest])
	for pair in [["hero", lead], ["attacker", partner]]:
		var b: Body = pair[1]
		for side in ["Left", "Right"]:
			var runs: Array[Vector2i] = _plants(b.frames, side)
			var worst := 0.0
			for run in runs:
				var first: Vector3 = b.frames[run.x][side + "Foot"]
				for f in range(run.x, run.y + 1):
					var at: Vector3 = b.frames[f][side + "Foot"]
					worst = maxf(worst, Vector2(at.x - first.x, at.z - first.z).length())
			r.append("  %s %s foot: %d plants, worst travel while planted %.4f m (spec <= 0.01)"
					% [pair[0], side.to_lower(), runs.size(), worst])


func _segments(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> float:
	var best := INF
	for i in 13:
		var p: Vector3 = a.lerp(b, i / 12.0)
		best = minf(best, _to_segment(p, c, d))
	return best


func _to_segment(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab: Vector3 = b - a
	return p.distance_to(a + ab * clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0))


func _show(b: Body, clip: Animation) -> void:
	var library := AnimationLibrary.new()
	library.add_animation(&"probe", clip)
	b.player.add_animation_library(&"_probe", library)
	b.player.play(&"_probe/probe")


func _hide(b: Body) -> void:
	b.player.stop()
	b.player.remove_animation_library(&"_probe")
