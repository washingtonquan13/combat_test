extends SceneTree

# Generates assets/duel_animations.tres, the "Duel" library on the CC bodies:
# the single-body clips around the exchange in cinematics/duel_m2.tscn
# (docs/plans/bg3_cinematics.md, M2).
#
#   godot --headless --path . -s res://tools/kimodo/make_duel_animations.gd
#
#   Victim_Cornered   backs away, hands up, cowers, then looks up (female)
#   Hero_Drop         a run, a long leap and a hard landing in a crouch,
#                     rising into a stance, sword in hand (male)
#   Attacker_Advance  a slow, menacing walk, sword low (male)
#   Hero_After        lowers the sword, then looks down at the body (male)
#
# Each is one Kimodo take (tools/kimodo/takes/duel_*, with the text that made
# it), picked from four seeds by skate and jerk (tools/kimodo/score_take.py).
# Posture is the take's own. What is done here, and nothing else:
#
#   Where it stands. A clip that ENDS on a mark (the victim's corner, the
#   hero's landing, the attacker's place in the exchange) is placed so its
#   last frame stands over the origin facing +Z: the unit waits on the mark
#   and the clip carries the body in. One that STARTS on a mark (Hero_After,
#   from where the exchange leaves the hero) is placed by its first frame.
#   Planted feet. Pinned, as make_exchange_animations.gd does it (the plan
#   allows that and the contact IK; nothing else).
#
# The numbers it prints (planted-foot travel, the hero's landing frame) are
# part of M2's exit criteria.

const Exchange := preload("res://tools/kimodo/make_exchange_animations.gd")
const Retarget := preload("res://tools/kimodo/soma_retarget.gd")

const OUT := "res://assets/duel_animations.tres"
const MALE := "res://scenes/character_models/cc_male_model.tscn"
const FEMALE := "res://scenes/character_models/cc_female_model.tscn"
const TAKES := "res://tools/kimodo/takes/"

## [clip, take, model, first frame, last frame (-1 = the take's last),
## placed by its last frame (true) or its first, holds a sword].
const CLIPS := [
	["Victim_Cornered", "duel_victim", FEMALE, 0, -1, true, false],
	["Hero_Drop", "duel_hero_drop", MALE, 0, 48, true, true],
	["Attacker_Advance", "duel_attacker_walk", MALE, 0, -1, true, true],
	["Hero_After", "duel_hero_after", MALE, 0, -1, false, true],
]

## Both feet this far above the floor make the body airborne; the landing
## is the first frame after that a foot is down again.
const AIRBORNE := 0.12
const STOPPED := 0.01


func _initialize() -> void:
	_bake.call_deferred()


func _bake() -> void:
	await process_frame
	var helper: Object = Exchange.new()
	var library := AnimationLibrary.new()
	var report: PackedStringArray = []
	for entry: Array in CLIPS:
		var b = Exchange.Body.new()
		b.model = (load(entry[2]) as PackedScene).instantiate()
		root.add_child(b.model)
		await process_frame
		b.skeleton = b.model.find_child("GeneralSkeleton", true, false)
		b.player = b.model.get_node("Body/AnimationPlayer")
		b.grip = b.model.get("main_hand_grip")
		b.take = Retarget.new()
		if not b.take.read(TAKES + entry[1]):
			push_error("take missing: %s" % entry[1])
			quit(1)
			return
		var first: int = entry[3]
		var last: int = entry[4] if entry[4] >= 0 else b.take.frames - 1
		var placed: Transform3D = b.take.squared(last if entry[5] else first)
		var fingers: Animation = b.player.get_animation(&"Weapon/Stance_Sword") if entry[6] else null
		b.clip = b.take.animation(b.skeleton, first, last, placed, fingers)
		var count: int = last - first
		var before: Dictionary = _travel(helper, b, count)
		for pass_i in 3:
			helper._pin_feet(b)
		var after: Dictionary = _travel(helper, b, count)
		var rows: Array[Dictionary] = helper._sample(b, b.clip, count)
		var end: Vector3 = rows[-1].hips if entry[5] else rows[0].hips
		report.append("%s: %d frames (%.2f s) from %s %d..%d; hips %s %s; planted-foot travel worst L %.4f R %.4f m (before pins %.4f / %.4f)" % [
				entry[0], count + 1, b.clip.length, entry[1], first, last,
				"end" if entry[5] else "start", Vector3(end.x, 0.0, end.z),
				after.Left, after.Right, before.Left, before.Right])
		if entry[0] == "Hero_Drop":
			report.append("Hero_Drop: landing on clip frame %d (%.3f s)" % [_landing(rows), _landing(rows) / Retarget.FPS])
		library.add_animation(StringName(entry[0]), b.clip)
		b.model.queue_free()
	helper.free()
	var err: Error = ResourceSaver.save(library, OUT)
	for line in report:
		print(line)
	print("%s: %s" % [OUT, error_string(err)])
	quit(0 if err == OK else 1)


# Worst flat travel of each foot over any of its plants, in metres.
func _travel(helper: Object, b, count: int) -> Dictionary:
	var rows: Array[Dictionary] = helper._sample(b, b.clip, count)
	var out := {}
	for side in ["Left", "Right"]:
		var worst := 0.0
		for run: Vector2i in helper._plants(rows, side):
			for f in range(run.x, run.y + 1):
				var d: Vector3 = rows[f][side + "Foot"] - rows[run.x][side + "Foot"]
				worst = maxf(worst, Vector2(d.x, d.z).length())
		out[side] = worst
	return out


# The first frame a foot comes to rest after both were off the floor: it
# is low (under AIRBORNE) and stops falling (under STOPPED a frame). Not a
# fixed floor height: a retargeted body's feet rest at different heights
# (a deep crouch puts one ankle lower than the other's plant).
func _landing(rows: Array[Dictionary]) -> int:
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
