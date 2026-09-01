extends AiTestCase
## A body with no animation library still finishes what it starts.
##
## This is the whiteboxing prerequisite. Before it, a unit could not act
## without art: `_advance_to_next_phase()` played a clip and then waited
## according to the phase trigger, and of the three triggers only
## ON_FINISH — the DEFAULT — had no backstop at all.
##
##   ON_TIMER   creates a timer
##   EXTERNAL   checks a pending flag
##   ON_FINISH  waits for animation_finished
##
## `_play()` on a missing clip warned and did nothing, so nothing was
## playing, so `animation_finished` never arrived and the sequence sat on
## its first phase forever. Every later phase — including the impact step
## an ability's timing waits on — was unreachable. That is the family the
## jump-animation stall belongs to.
##
## Both directions are asserted here, and the second matters as much as
## the first: a sequence whose clips DO exist must still wait for them.
## A fix that made every sequence race through would pass the whitebox
## check and quietly destroy every animation in the game.
##
## Reaches into `_play_sequence` and `_active_sequence` deliberately. That
## state IS the subject — "the sequence advanced" is not observable from
## outside without building a rig that tests plumbing instead of the fix —
## and this suite follows the precedent of the mode-claim test that read
## CombatManager's own counters for the same reason.


func run() -> void:
	var unit: Unit = spawn_unit(&"player", 12, 12, 20, [melee()], Vector3.ZERO)
	await get_tree().process_frame

	var animator: Node = unit.get_node("UnitAnimator")
	var player: AnimationPlayer = animator.animation_player
	if player == null:
		check("SETUP: the unit has an AnimationPlayer to strip", false)
		free_spawned()
		return

	# A clip that really exists, captured before the library goes, so the
	# second half can prove the wait still happens.
	var real_clip: String = ""
	var names: PackedStringArray = player.get_animation_list()
	if names.size() > 0:
		real_clip = names[0]

	check("SETUP: the body started with an animation library",
		real_clip != "", "nothing to strip, so the whitebox case cannot be built")
	if real_clip == "":
		free_spawned()
		return

	# --- with clips: the sequence must still WAIT ---------------------
	var waiting := _sequence_of([real_clip, real_clip])
	animator._play_sequence(waiting)
	check("a sequence whose clip exists waits for it, as it always did",
		animator._active_sequence == waiting,
		"the sequence ran straight through — every animation in the game " +
		"would now be skipped")

	# --- strip the library, then the same shape must COMPLETE ---------
	for library in player.get_animation_library_list():
		player.remove_animation_library(library)

	check("SETUP: the body now has no clips at all",
		player.get_animation_list().size() == 0,
		"%d clip(s) survived the strip" % player.get_animation_list().size())

	var whitebox := _sequence_of(["missing_a", "missing_b", "missing_c"])
	animator._play_sequence(whitebox)

	# No await: skipping is synchronous, which is the point — the turn
	# never has to wait on something that is never coming.
	check("a sequence of missing clips completes instead of stalling",
		animator._active_sequence == null,
		"still holding phase %d of %d — this is the stall" % [
			animator._active_phase_index, whitebox.phases.size()])

	# And the real thing: a unit with no art at all can use an ability.
	unit.use_ability(unit.abilities[0], unit)
	await get_tree().process_frame
	check("and an ability used by an animation-less body does not strand it",
		animator._active_sequence == null,
		"the cast sequence is stuck on phase %d" % animator._active_phase_index)

	free_spawned()


## Every phase ON_FINISH, which is both the default and the trigger that
## had no escape hatch.
func _sequence_of(clips: Array) -> AnimationSequence:
	var sequence := AnimationSequence.new()
	var phases: Array[AnimationPhase] = []
	for clip in clips:
		var phase := AnimationPhase.new()
		phase.animation_name = clip
		phase.advance_trigger = AnimationPhase.AdvanceTrigger.ON_FINISH
		phases.append(phase)
	sequence.phases = phases
	return sequence
