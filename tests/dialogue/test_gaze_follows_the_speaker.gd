extends AiTestCase
## Heads turn toward whoever is talking.
##
## The first suite in tests/dialogue/ at all. The 2026-09-02 audit found
## DialogueManager referenced by ZERO of 41 suites while carrying a
## documented history of failing silently — a 32-of-32 green UI run once
## passed while the dialogue and negotiation panels rendered invisible. So
## this asserts the rendered fact (a modifier actually aimed at a node)
## rather than that a method was called.
##
## What is under test is the DECISION, not Godot's LookAtModifier3D: who
## looks at whom, that the aim follows a change of speaker, that echo
## lines do not re-aim, that a body which cannot track says so instead of
## throwing, and that gazes are released when the conversation ends.
##
## WHY THERE IS A BYSTANDER BOUND TO "". The first version of this suite
## tested the echo-line rule by emitting an empty speaker token against a
## two-participant table — and that check could not fail. An empty token
## finds no participant, so DialogueGaze's own is_instance_valid guard
## returns early whether or not the rule it is meant to prove exists.
## Sabotaging the rule left the suite green. Binding a real unit to ""
## makes the guard the only thing standing between an echo line and a
## re-aim, which is what the check claims to be testing.

const SPEAKER := &"npc"
const LISTENER := &"player"
## Deliberately the empty token — see the header.
const ECHO := &""

var _saved_participants: Dictionary = {}
var _gaze: DialogueGaze = null


func run() -> void:
	var speaker: Unit = spawn_brute(0.0, 0.0)
	var listener: Unit = spawn_brute(3.0, 0.0)
	var bystander: Unit = spawn_brute(0.0, 3.0)
	await get_tree().process_frame

	_saved_participants = DialogueManager.participants.duplicate()
	DialogueManager.participants = {
		SPEAKER: speaker, LISTENER: listener, ECHO: bystander,
	}

	_gaze = DialogueGaze.new()
	_root.add_child(_gaze)
	await get_tree().process_frame

	# --- the body can be looked at at all ------------------------------
	var point: Node3D = speaker.gaze_point()
	check("a body offers something to look at",
		point != null,
		"gaze_point() returned null, so nobody can be looked at and every " +
		"check below is vacuous")

	if point:
		var head_height: float = point.global_position.y - speaker.global_position.y
		check("and it is at the face, not the feet",
			head_height > 1.0,
			"gaze point sits %.2fm above the unit — aiming here would make " % head_height +
			"every head stare at the floor")

	# --- the decision --------------------------------------------------
	DialogueManager.line_shown.emit("Hello.", String(SPEAKER))
	await get_tree().process_frame

	var listener_gaze: LookAtModifier3D = _modifier_of(listener)
	check("the listener's head is aimed at the speaker",
		listener_gaze != null and listener_gaze.influence > 0.0,
		"no active modifier on the listener — %s" % (
			"none was resolved at all" if listener_gaze == null else "influence is 0"))

	check("and aimed at the SPEAKER specifically, not just at something",
		_is_aimed_at(listener_gaze, speaker),
		"aimed at %s, which is not part of the speaker" % _aim_description(listener_gaze))

	# The only asymmetric part of the decision: everyone else looks at the
	# talker, and the talker has to look at somebody or they are the one
	# person in the room staring into space.
	var talker: LookAtModifier3D = _modifier_of(speaker)
	check("and the speaker looks at whoever they are addressing",
		talker != null and talker.influence > 0.0 and not _is_aimed_at(talker, speaker),
		"the person talking is aimed at %s" % _aim_description(talker))

	# --- the aim follows a change of speaker ---------------------------
	# The positive half of the echo rule. Without this, a DialogueGaze that
	# aimed once and then ignored every later line would still pass.
	DialogueManager.line_shown.emit("My turn.", String(LISTENER))
	await get_tree().process_frame

	var speaker_gaze: LookAtModifier3D = _modifier_of(speaker)
	check("when the speaker changes, the room turns to the new one",
		_is_aimed_at(speaker_gaze, listener),
		"the original speaker is aimed at %s after someone else spoke" % _aim_description(speaker_gaze))

	# --- and does not follow a line nobody spoke -----------------------
	var before: NodePath = speaker_gaze.target_node if speaker_gaze else NodePath()
	DialogueManager.line_shown.emit("(you feel uneasy)", String(ECHO))
	await get_tree().process_frame
	check("an echo line with no speaker does not re-aim anyone",
		speaker_gaze == null or speaker_gaze.target_node == before,
		"the cast turned toward a line nobody spoke — same rule " +
		"dialogue_camera_rig.gd already follows for shot changes")

	# --- release -------------------------------------------------------
	DialogueManager.dialogue_ended.emit()
	await get_tree().process_frame
	check("ending the conversation releases the gaze",
		listener_gaze == null or listener_gaze.influence == 0.0,
		"influence is still %.2f, so the head stays turned after everyone " % (
			0.0 if listener_gaze == null else listener_gaze.influence) +
		"has stopped talking")

	# --- the rig is wired so the gaze can work at all -------------------
	_check_the_modifier_is_wired(listener)

	# --- degradation ---------------------------------------------------
	var bodiless := Unit.new()
	_root.add_child(bodiless)
	await get_tree().process_frame
	check("a unit with no body declines to gaze rather than erroring",
		not bodiless.gaze_at(listener),
		"gaze_at returned true for a unit that has no CharacterModel")
	bodiless.queue_free()

	_cleanup()


## The bone must actually resolve, and the neck must have a limit.
##
## RESULTING ROTATION IS NOT ASSERTED, because it cannot be: measured
## directly, LookAtModifier3D does not move a bone at all under --headless
## even with the skeleton linked, the bone resolved, influence at 1 and a
## live target. Every reading of get_bone_pose_rotation comes back at rest.
## So this asserts the configuration that produces the behaviour, and the
## behaviour itself is a look-at-it check.
##
## That is a real weakness and worth stating plainly rather than dressing
## a config assertion up as a behavioural one.
##
## The bone check is deliberately weak: it catches a body whose rig has no
## Head bone, and nothing subtler. It does NOT guard the resolution-order
## hazard that turned up while writing this — a SkeletonModifier3D cannot
## resolve bone_name until its own tree entry is processed, which is a real
## trap in other setups but not on this path, because the skeleton is
## already in the tree by the time a body is asked to gaze. Sabotaging the
## index assignment leaves this green, and it should.
func _check_the_modifier_is_wired(unit: Unit) -> void:
	var modifier: LookAtModifier3D = _modifier_of(unit)
	if modifier == null:
		check("SETUP: a modifier exists to inspect", false)
		return

	check("the modifier resolved a real bone",
		modifier.bone >= 0,
		"bone is %d. A SkeletonModifier3D finds its skeleton only on the " % modifier.bone +
		"frame AFTER parenting, so setting bone_name any earlier leaves it " +
		"at -1 and the gaze silently does nothing forever")

	check("and it is parented to the skeleton it drives",
		modifier.get_parent() is Skeleton3D,
		"parent is %s — a modifier outside a Skeleton3D never runs" % (
			"nothing" if modifier.get_parent() == null else modifier.get_parent().get_class()))

	check("and the neck is limited rather than free to spin",
		modifier.use_angle_limitation
			and modifier.primary_limit_angle < TAU
			and modifier.secondary_limit_angle < TAU,
		"limitation=%s yaw=%.0f deg pitch=%.0f deg — Godot ships this off, " % [
			str(modifier.use_angle_limitation),
			rad_to_deg(modifier.primary_limit_angle),
			rad_to_deg(modifier.secondary_limit_angle)] +
		"and enabling it alone changes nothing because both angles default " +
		"to a full circle. Unlimited means a speaker behind you turns a " +
		"head the whole way round")


## Whether `modifier` is currently pointed at any part of `unit`.
func _is_aimed_at(modifier: LookAtModifier3D, unit: Unit) -> bool:
	if modifier == null or modifier.influence <= 0.0:
		return false
	var target: Node = modifier.get_node_or_null(modifier.target_node)
	return target != null and unit.is_ancestor_of(target)


func _aim_description(modifier: LookAtModifier3D) -> String:
	if modifier == null:
		return "no modifier at all"
	if modifier.influence <= 0.0:
		return "nothing — influence is 0"
	var target: Node = modifier.get_node_or_null(modifier.target_node)
	return "nothing" if target == null else str(target.get_path())


## The modifier the body actually resolved, found through the skeleton
## rather than through CharacterModel's private field — so this asserts
## the thing that exists in the tree, not the thing we think we made.
func _modifier_of(unit: Unit) -> LookAtModifier3D:
	var body := unit.get_node_or_null("CharacterModel")
	if body == null:
		return null
	return _find_modifier(body)


func _find_modifier(node: Node) -> LookAtModifier3D:
	for child in node.get_children():
		if child is LookAtModifier3D:
			return child
		var deeper: LookAtModifier3D = _find_modifier(child)
		if deeper:
			return deeper
	return null


func _cleanup() -> void:
	if is_instance_valid(_gaze):
		_gaze.queue_free()
	DialogueManager.participants = _saved_participants
