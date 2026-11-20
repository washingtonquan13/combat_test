extends SceneTree

# Generates assets/fight_animations.tres (the "Fight" library on the CC
# bodies) and assets/paired_clips/duel.tres, the PairedClip that plays it.
#
#   godot --headless --path . -s res://tools/kimodo/make_fight_animations.gd
#
# Duel: two swordsmen on guard. The lead brings an overhead cut down on the
# partner's raised guard; the partner answers with a cut from the side,
# which the lead blocks; the lead lunges and runs the partner through the
# left shoulder, and the partner staggers back and keeps their feet.
#
#   Duel_Lead      the lead's half, baked on the male CC body
#   Duel_Partner   the partner's half, baked on the female CC body
#
# Each half is one Kimodo take (tools/kimodo/takes/fight_a and fight_b,
# with the text that made them), generated apart. What makes them a fight
# is done here:
#
#   Where they stand. The partner faces the lead from a place searched for
#   here: the one that brings the weapons closest to meeting on every
#   contact at once. It is saved in the PairedClip.
#   The same clock. The partner's take is retimed, piecewise, so each of
#   its contacts lands on the lead's frame for it.
#   The blades. Kimodo's hands hold nothing; a sword is put along each
#   forearm, and around each contact the wrists are turned so the blades
#   meet: the blocker's held across the blow, the striker's aimed at it.
#   Where they end. How far each body has travelled is measured and saved
#   (lead_end, partner_end) for the beat to move them by when they stand.
#
# Retune by changing the numbers below and running this again.

const Retarget := preload("res://tools/kimodo/soma_retarget.gd")

const OUT := "res://assets/fight_animations.tres"
const PAIR := "res://assets/paired_clips/duel.tres"
const LEAD_MODEL := "res://scenes/character_models/cc_male_model.tscn"
const PARTNER_MODEL := "res://scenes/character_models/cc_female_model.tscn"
const TAKES := "res://tools/kimodo/takes/"
const LEAD_TAKE := "fight_a"
const PARTNER_TAKE := "fight_b"

## From the grip to the sword's tip, along the grip's +Y.
const BLADE := 0.787
## The take frame both halves start on: the two takes are one motion until
## then (the same seed and first line), a step into guard.
const START := 30
## The lead's take frame its half ends on. After it the take falls apart.
const LEAD_LAST := 158
## Each contact, in take frames. lead: the lead's frame. partner: about
## where the partner's is; the search looks SEARCH frames either side.
## parry: blocker is whose guard takes the blow, across it (high: level,
## side: upright). hit: the lead's point lands in the partner's left
## shoulder.
const CONTACTS := [
	{lead = 50, partner = 50, kind = "parry", blocker = "partner", guard = "high"},
	{lead = 82, partner = 74, kind = "parry", blocker = "lead", guard = "side"},
	{lead = 113, partner = 114, kind = "hit"},
]
const SEARCH := 4
## Along the guarding blade, from its grip, where the blow lands on it.
const CROSS := 0.4
## Along the striking blade, from its grip, where it meets the guard.
const STRIKE := 0.55
## How far from the grip the thrust's point is at the shoulder: a little
## short of the whole blade, so the point is in.
const THRUST := 0.68
## Closest the two bodies' middles may come.
const APART := 0.9
## Frames the wrists take to turn into a contact, hold it, and let it go.
const AIM_IN := 6
const AIM_HOLD := 2
const AIM_OUT := 7
## A guard is set earlier than a blow arrives.
const GUARD_IN := 10

var _bodies := {}


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
	lead.frames = _sample(lead, lead.clip, last)
	partner.frames = _sample(partner, full, partner.take.frames - 1 - START)

	var fit: Dictionary = _fit(lead, partner)
	var placed: Transform3D = fit.placed
	var met: Array = fit.contacts
	print("Duel: partner at %s, turned %.1f deg; cost %.4f" % [placed.origin, rad_to_deg(placed.basis.get_euler().y), fit.cost])

	var map: Array[Vector2] = [Vector2.ZERO]
	for c: Dictionary in met:
		map.append(Vector2(c.lead, c.partner))
	var tail: float = met[-1].partner + (last - met[-1].lead)
	map.append(Vector2(last, minf(tail, partner.frames.size() - 1)))
	print("Duel: partner's clock (lead frame, partner frame): %s" % [map])
	partner.clip = _retimed(full, map, last)

	_armed(lead)
	_armed(partner)
	for c: Dictionary in met:
		_aim_contact(lead, partner, placed, c)

	lead.frames = _sample(lead, lead.clip, last)
	partner.frames = _sample(partner, partner.clip, last)
	_report(lead, partner, placed, met)

	var library := AnimationLibrary.new()
	library.add_animation(&"Duel_Lead", lead.clip)
	library.add_animation(&"Duel_Partner", partner.clip)
	var err: Error = ResourceSaver.save(library, OUT)
	print("%s: %s" % [OUT, error_string(err)])

	var pair := PairedClip.new()
	pair.lead_clip = "Fight/Duel_Lead"
	pair.partner_clip = "Fight/Duel_Partner"
	pair.partner_from_lead = placed
	var times := PackedFloat32Array()
	for c: Dictionary in met:
		times.append(c.lead / Retarget.FPS)
	pair.contacts = times
	pair.contact_time = times[0]
	pair.length = last / Retarget.FPS
	pair.kills_partner = false
	pair.lead_end = _travel(lead)
	pair.partner_end = _travel(partner)
	print("Duel: lead ends moved %s, partner %s" % [pair.lead_end.origin, pair.partner_end.origin])
	var saved: Error = ResourceSaver.save(pair, PAIR)
	print("%s: %s" % [PAIR, error_string(saved)])
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


# The take from START to `to`, standing over the origin on START, turned as
# its first frame faces (the fight runs along +Z from there).
func _base(b: Body, to: int) -> Animation:
	var squared: Transform3D = b.take.squared(0)
	var at: Vector3 = squared * b.take.world(START)[0].origin
	var placed := Transform3D(squared.basis, squared.origin - Vector3(at.x, 0.0, at.z))
	var fingers: Animation = b.player.get_animation(&"Weapon/Stance_Sword")
	return b.take.animation(b.skeleton, START, to, placed, fingers)


# Per frame, in the body's own space: the middle (hips), the grip, the
# blade's direction, the left shoulder.
func _sample(b: Body, clip: Animation, last: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	_show(b, clip)
	for f in last + 1:
		b.player.seek(f / Retarget.FPS, true)
		b.player.advance(0.0)
		var sk: Transform3D = b.skeleton.global_transform
		var hand: Transform3D = sk * b.skeleton.get_bone_global_pose(b.skeleton.find_bone("RightHand"))
		var grip: Transform3D = hand * b.grip.transform
		out.append({
			hips = (sk * b.skeleton.get_bone_global_pose(b.skeleton.find_bone("Hips"))).origin,
			grip = grip.origin,
			blade = grip.basis.y.normalized(),
			shoulder = (sk * b.skeleton.get_bone_global_pose(b.skeleton.find_bone("LeftUpperArm"))).origin,
		})
	_hide(b)
	return out


# Where the partner stands (in the lead's space) and on which of its frames
# each contact lands: searched, for the weapons nearest to meeting on all
# of them.
func _fit(lead: Body, partner: Body) -> Dictionary:
	var best := {cost = INF}
	for turn_deg in range(-20, 21, 5):
		var basis := Basis(Vector3.UP, PI + deg_to_rad(turn_deg))
		for xi in range(-15, 51):
			for zi in range(25, 76):
				var placed := Transform3D(basis, Vector3(xi * 0.04, 0.0, zi * 0.04))
				var cost := 0.0
				var picks: Array = []
				for c: Dictionary in CONTACTS:
					var pick := _best_frame(lead, partner, placed, c)
					cost += pick.cost
					picks.append(pick)
					if cost >= best.cost:
						break
				if cost < best.cost:
					best = {cost = cost, placed = placed, contacts = picks}
	var at := -1
	for c: Dictionary in best.contacts:
		if c.partner <= at:
			push_warning("partner's contacts out of order: %s" % [best.contacts])
		at = c.partner
	return best


func _best_frame(lead: Body, partner: Body, placed: Transform3D, c: Dictionary) -> Dictionary:
	var fl: int = c.lead - START
	var pick := {cost = INF}
	for fp in range(c.partner - START - SEARCH, c.partner - START + SEARCH + 1):
		if fp < 0 or fp >= partner.frames.size():
			continue
		var cost := _contact_cost(lead.frames[fl], partner.frames[fp], placed, c)
		if cost < pick.cost:
			pick = {cost = cost, lead = fl, partner = fp, kind = c.kind,
				blocker = c.get("blocker", ""), guard = c.get("guard", "")}
	return pick


func _contact_cost(l: Dictionary, p: Dictionary, placed: Transform3D, c: Dictionary) -> float:
	var hips: Vector3 = placed * p.hips
	var apart: Vector3 = hips - l.hips
	apart.y = 0.0
	var cost: float = 4.0 * pow(maxf(0.0, APART - apart.length()), 2)
	if c.kind == "hit":
		var into: float = (placed * p.shoulder).distance_to(l.grip) - THRUST
		return cost + into * into
	var meet: Dictionary = _meeting(l, p, placed, c)
	var off: float = meet.striker_grip.distance_to(meet.at) - STRIKE
	return cost + off * off


# Where a parry's blades meet (lead's space), and which way the guard lies.
func _meeting(l: Dictionary, p: Dictionary, placed: Transform3D, c: Dictionary) -> Dictionary:
	var lead_guards: bool = c.blocker == "lead"
	var guard_grip: Vector3 = l.grip if lead_guards else placed * p.grip
	var striker_grip: Vector3 = placed * p.grip if lead_guards else l.grip
	var line: Vector3 = placed * p.hips - l.hips
	line.y = 0.0
	var across: Vector3 = Vector3.UP.cross(line.normalized())
	var best := {}
	for side in [1.0, -1.0]:
		var lie: Vector3 = across * side
		if c.guard == "side":
			lie = (Vector3.UP * 0.8 + lie * 0.6).normalized()
		var at: Vector3 = guard_grip + lie * CROSS
		var d: float = absf(striker_grip.distance_to(at) - STRIKE)
		if best.is_empty() or d < best.d:
			best = {d = d, at = at, lie = lie, striker_grip = striker_grip, lead_guards = lead_guards}
	return best


# The partner's clip with its frames moved so each `map` point (lead frame,
# partner frame) lines up, straight between them.
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
	_turn_wrist(b, func(_f: int, forearm: Transform3D, wrist: Transform3D, _blade: Vector3) -> Dictionary:
		return {dir = (wrist.origin - forearm.origin).normalized(), weight = 1.0})


# Around one contact, the wrists turned so the blades meet.
func _aim_contact(lead: Body, partner: Body, placed: Transform3D, c: Dictionary) -> void:
	# The partner's frames are still on its own clock here.
	var l: Dictionary = lead.frames[c.lead]
	var p: Dictionary = partner.frames[c.partner]
	var inv: Transform3D = placed.affine_inverse()
	if c.kind == "hit":
		var at: Vector3 = placed * p.shoulder
		_aim(lead, c.lead, at, AIM_IN, AIM_HOLD + 2)
		return
	var meet: Dictionary = _meeting(l, p, placed, c)
	if meet.lead_guards:
		_lie(lead, c.lead, meet.lie)
		_aim(partner, c.lead, inv * meet.at, AIM_IN, AIM_HOLD)
	else:
		_lie(partner, c.lead, inv.basis * meet.lie)
		_aim(lead, c.lead, meet.at, AIM_IN, AIM_HOLD)


# The blade aimed through `at` (the body's own space) on frame `on`.
func _aim(b: Body, on: int, at: Vector3, into: int, hold: int) -> void:
	var sk_at: Vector3 = b.skeleton.global_transform.affine_inverse() * at
	_turn_wrist(b, func(f: int, _forearm: Transform3D, wrist: Transform3D, _blade: Vector3) -> Dictionary:
		var grip: Vector3 = wrist * b.grip.transform.origin
		return {dir = (sk_at - grip).normalized(), weight = _window(f, on, into, hold)})


# The blade held along `lie` (the body's own space) around frame `on`.
func _lie(b: Body, on: int, lie: Vector3) -> void:
	var sk_lie: Vector3 = (b.skeleton.global_transform.basis.inverse() * lie).normalized()
	_turn_wrist(b, func(f: int, _forearm: Transform3D, _wrist: Transform3D, _blade: Vector3) -> Dictionary:
		return {dir = sk_lie, weight = _window(f, on, GUARD_IN, AIM_HOLD)})


func _window(f: int, on: int, into: int, hold: int) -> float:
	if f < on:
		return smoothstep(float(on - into), float(on), float(f))
	if f <= on + hold:
		return 1.0
	return 1.0 - smoothstep(float(on + hold), float(on + hold + AIM_OUT), float(f))


# For each key of the right hand's track, `want` gives the blade a direction
# (skeleton space) and how far to turn toward it.
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


# How far the body's middle has moved, flat, from the clip's first frame to
# its last; it ends still facing its opponent.
func _travel(b: Body) -> Transform3D:
	var moved: Vector3 = b.frames[-1].hips - b.frames[0].hips
	return Transform3D(Basis.IDENTITY, Vector3(moved.x, 0.0, moved.z))


func _report(lead: Body, partner: Body, placed: Transform3D, met: Array) -> void:
	var closest := INF
	for f in lead.frames.size():
		var d: Vector3 = placed * partner.frames[f].hips - lead.frames[f].hips
		d.y = 0.0
		closest = minf(closest, d.length())
	print("Duel: closest the bodies come: %.2f m" % closest)
	for c: Dictionary in met:
		var l: Dictionary = lead.frames[c.lead]
		var p: Dictionary = partner.frames[c.lead]
		var la: Vector3 = l.grip
		var lb: Vector3 = l.grip + l.blade * BLADE
		var pa: Vector3 = placed * p.grip
		var pb: Vector3 = placed * (p.grip + p.blade * BLADE)
		if c.kind == "hit":
			var sh: Vector3 = placed * p.shoulder
			print("  %s frame %d: point %.3f m from the shoulder, blade passes %.3f m from it"
					% [c.kind, c.lead, lb.distance_to(sh), _to_segment(sh, la, lb)])
		else:
			print("  %s frame %d (partner %d): blades %.3f m apart, grips %.2f m"
					% [c.kind, c.lead, c.partner, _segments(la, lb, pa, pb), la.distance_to(pa)])


func _to_segment(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab: Vector3 = b - a
	return p.distance_to(a + ab * clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0))


func _segments(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> float:
	var best := INF
	for i in 41:
		var p: Vector3 = a.lerp(b, i / 40.0)
		best = minf(best, _to_segment(p, c, d))
	return best


func _show(b: Body, clip: Animation) -> void:
	var library := AnimationLibrary.new()
	library.add_animation(&"probe", clip)
	b.player.add_animation_library(&"_probe", library)
	b.player.play(&"_probe/probe")


func _hide(b: Body) -> void:
	b.player.stop()
	b.player.remove_animation_library(&"_probe")
