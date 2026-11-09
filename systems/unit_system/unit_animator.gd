class_name UnitAnimator
extends Node
## Drives this unit's AnimationPlayer in response to existing Unit/
## ability signals — a thin translation layer between "game state
## changed" and "play this clip (or sequence of clips)," so unit.gd
## itself never needs to know or care about animation names or timing.
##
## Scene setup: attach to a plain child Node of your Unit (NOT inside
## the imported .glb — you can't attach scripts to nodes owned by an
## imported scene). Drag your Unit into `unit`, drag the AnimationPlayer
## from inside your instanced/editable-children .glb into
## `animation_player`.
##
## An ability's cast motion is driven entirely by data (see
## AnimationSequence/AnimationPhase) rather than hardcoded per ability
## shape — this script has no idea what a "melee attack," "spell," or
## "jump" is anymore. ability.motion names a motion key, and the body's
## MotionSet (CharacterModel.motions) answers it with an ordered list of
## phases, falling back by category (&"cast.charged" -> &"cast");
## this script just plays each phase's clip and advances to the next one
## whenever that phase's own AdvanceTrigger says to — see
## _advance_to_next_phase()/_active_phase() near the bottom of this file
## for the actual player.
##
## Moments: a cast clip marks when the cast lets go and when it lands
## with Call Method Track keys calling CharacterModel.release() or
## .impact() (track path ".." from the body's AnimationPlayer). They
## arrive here as CharacterModel.moment. "release" releases the
## AbilityAction (the projectile and cast VFX start on
## Unit.cast_released); "impact" is Unit.notify_impact(), which lands an
## ability whose AbilityTiming.waits_for_impact is on. Keys are placed by
## hand in the AnimationPlayer editor, e.g. Spell_Simple_Shoot release
## 0.2, Jump_Start impact 0.55 (generated, tools/make_weapon_animations.gd), fireball Cast release 0.3. The cast
## always lets go: at the sequence's end if no clip had a key, when the
## sequence is abandoned or replaced, on a hit reaction or death, at once
## for an ability with no cast animation, and at UnitCombat's
## RELEASE_TIMEOUT if all else fails. impact_timeout counts from the
## release, so a missing impact key doesn't hang the turn either.
##
## OWNS Unit.visual_state/posed_status — this is the only script that
## ever writes to them, same as it's the only thing that ever decides
## which clip plays. They live on Unit rather than staying private here
## (an earlier version of this file had its own local copies) so
## unit_vfx.gd/unit_sfx.gd can read "is this unit currently posed, by
## which status" without independently re-deriving that tracking
## themselves — see Unit.VisualState's own doc comment for the bug that
## happened once already from each reactive system quietly assuming its
## own answer to that question.

@export var unit: Unit
@export var animation_player: AnimationPlayer

@export_group("Clip Names")
@export var idle_animation: String = "Idle"
@export var walk_animation: String = "Jog_Fwd"
@export var hit_animation: String = "Hit_Chest"
@export var death_animation: String = "Death01"

@export_group("Pacing")
## The beat after an attack's clip settles before the turn moves on.
## The unit is held busy (Unit.begin_busy) through its attack's clip and
## this gap, so the next turn doesn't start mid-recovery.
@export var turn_gap: float = 0.35

@export_group("Blending")
## The crossfade into a stance clip (an armed enter, hold or exit) and into
## the cast that launches from it. Those are the clips that start while
## something else is mid-motion - arming from partway through the idle
## loop, disarming or casting from partway through the hold - so a hard
## cut would pop. Cast sequences have their own, phase_blend_time.
@export var stance_blend_time: float = 0.15
## The crossfade into each phase of a cast sequence, and from its last
## phase back to rest. A cast starts from wherever the idle loop happens to
## be, and a phase that advances on a timer or on an outside event (Jump's
## wind-up and its airborne hold) is cut off mid-motion, so with no
## crossfade the body snaps to the next clip's pose - Jump's knee turned
## 90 degrees in a single frame at each of its three changes.
@export var phase_blend_time: float = 0.2

@export_group("Flight Animation")
## See CharacterModel's own Flight Animation group; empty falls back to
## the ground clip.
@export var fly_idle_animation: String = ""
@export var fly_move_animation: String = ""
@export var takeoff_animation: String = ""
@export var land_animation: String = ""

@export_group("Ladder Animation")
## See CharacterModel's own Ladder Animation group.
@export var climb_animation: String = ""
@export var climb_off_animation: String = ""
@export var climb_on_animation: String = ""

## What a one-shot clip (a hit reaction, most commonly) returns to once
## it finishes — idle_animation normally, or the held status's pose
## (_posed_clip) while unit.visual_state == POSED. The single source
## every fallback reads from, kept correct in exactly the two places a
## pose starts/ends (_on_status_applied/_on_status_removed) instead of
## re-derived ad hoc wherever a one-shot clip happens to finish.
var _base_animation: String = ""

## Which AnimationSequence is currently being played through
## _play_sequence(), and which phase within it — null/-1 when nothing's
## active. Kept as plain state here (not inside a suspended coroutine)
## specifically so an interruption (a hit reaction stealing the
## AnimationPlayer) can't strand anything waiting on an
## animation_finished that will never come — see AnimationSequence's
## own header for the full reasoning.
var _active_sequence: AnimationSequence = null
var _active_phase_index: int = -1
## The ability use the active sequence is showing, until it releases
## (AbilityAction.release): at the clip's release key (CharacterModel's
## moment, relayed by _on_model_moment), or else when the sequence ends
## or is cut short — whichever comes first. Held here, not read off
## Unit.current_action, because a miss finishes the action in the same
## frame it starts and the shot still has to fly.
var _cast_action: AbilityAction = null
## The busy hold an attack's clip keeps on the unit (see turn_gap), and
## the token that tells its safety timer it's stale.
var _holding_busy: bool = false
var _hold_token: int = 0
## Longest a hold may last whatever happens to the clip.
const MAX_HOLD := 6.0
## Bumped every time _play_sequence starts a new play-through — captured
## by ON_TIMER phases so a stale timer from an already-abandoned
## play-through recognizes itself as stale at fire time, instead of
## force-advancing whatever sequence happens to be active by then.
var _sequence_token: int = 0
## Set when advance_external() is called before the active sequence has
## actually reached its EXTERNAL phase yet, and consumed the instant
## _advance_to_next_phase() lands on one — see advance_external()'s own
## doc comment for the real, confirmed race this guards against (a
## physical event arriving before the clip that's supposed to still be
## playing has finished).
var _external_advance_pending: bool = false

## Which clip _on_ability_armed() is currently waiting on to naturally
## finish before it starts the hold loop, and what to hold on once it
## does — both cleared the instant either happens (see
## _on_animation_finished's guard, which only consumes these when
## anim_name actually matches _pending_armed_enter_clip, so an unrelated
## clip finishing — a hit reaction interrupting mid-enter, say — can't
## be misread as the enter clip completing). Kept as simple string state
## rather than routed through the cast-sequence machinery above: enter-
## then-hold is a plainer one-shot-then-loop shape that doesn't need
## multi-phase composition, matching armed_enter_sfx/armed_enter_vfx's
## own single-moment shape rather than stretching AnimationSequence
## (built for a different kind of "one thing ends, decide what's next")
## onto something that doesn't need it.
var _pending_armed_enter_clip: String = ""
var _pending_armed_hold: String = ""

## The stance this unit is showing for its armed ability - the enter and
## hold clips it played, and the exit to play when it disarms. Disarming
## only puts the stance away if one of those clips is still what's on
## screen: the auto-disarm after a cast arrives while the cast is playing,
## and must not cut it.
var _armed_stance_clips: Array[String] = []
var _armed_exit_clip: String = ""

## Whether the body is off the ground, which is not quite unit.is_flying():
## the flying status is gone the moment a landing starts, but the body is
## still in the air until the descent ends (Unit.touched_down). Set by
## took_off, or by a flight status turning up without one (a unit spawned
## or loaded already flying); cleared only by touched_down. Passed on to
## the body (CharacterModel.aloft), for its wings.
var _aloft: bool = false:
	set(value):
		_aloft = value
		if is_instance_valid(_model):
			_model.aloft = value

## The body adopted last (adopt_model), told when it goes aloft.
var _model: CharacterModel = null

## Where the drawn weapon's stance comes from (UnitWeapons.stance), and
## the stance last applied: _idle()'s answer while on the ground.
var _weapons: UnitWeapons = null
var _stance: StringName = &""

## The body's answer to every motion key (CharacterModel.motions), taken in
## adopt_model. Null is a body with no motions: every cast releases at once
## and no stance, pose or gesture plays.
var _motions: MotionSet = null

## The clip the held status pose (unit.posed_status) is resting on, as its
## apply_motion resolved on this body. "" while not posed.
var _posed_clip: String = ""


## Rebinds this driver onto a body it was not authored against.
##
## Called by Unit._enter_tree(), which is BEFORE this node's own _ready —
## and that ordering is the whole trick. Nothing has connected to the
## outgoing AnimationPlayer yet, and the clip names assigned here are read
## by _ready a moment later, so no rewiring or teardown is needed.
##
## The names come from the BODY because that is what they describe. A
## dragon whose loop is called Fly_Idle should not need a different Unit
## scene to say so.
func adopt_model(model: CharacterModel) -> void:
	animation_player = model.resolve_animation_player()
	idle_animation = model.idle_animation
	walk_animation = model.walk_animation
	hit_animation = model.hit_animation
	death_animation = model.death_animation
	_motions = model.motions
	fly_idle_animation = model.fly_idle_animation
	fly_move_animation = model.fly_move_animation
	takeoff_animation = model.takeoff_animation
	land_animation = model.land_animation
	climb_animation = model.climb_animation
	climb_off_animation = model.climb_off_animation
	climb_on_animation = model.climb_on_animation
	model.moment.connect(_on_model_moment)
	_model = model
	model.aloft = _aloft


func _ready() -> void:
	if not unit or not animation_player:
		push_warning("unit_animator.gd needs both `unit` and `animation_player` assigned in the Inspector.")
		return

	AbilityManager.ability_armed.connect(_on_ability_armed)
	unit.movement_started.connect(_on_movement_started)
	unit.movement_finished.connect(_on_movement_finished)
	unit.ability_use_started.connect(_on_ability_use_started)
	unit.took_damage.connect(_on_took_damage)
	unit.died.connect(_on_died)
	unit.became_idle.connect(_on_unit_became_idle)
	unit.status_applied.connect(_on_status_applied)
	unit.status_removed.connect(_on_status_removed)
	unit.took_off.connect(_on_took_off)
	unit.touched_down.connect(_on_touched_down)
	unit.facing_swung.connect(_on_facing_swung)
	animation_player.animation_finished.connect(_on_animation_finished)
	_weapons = unit.get_node_or_null("UnitWeapons") as UnitWeapons
	if _weapons:
		_weapons.stance_changed.connect(_on_stance_changed)

	_validate_animation_names()

	# Not unit.is_flying(): this runs before Unit._ready has built its
	# statuses. A unit that starts flying gets its status after this, and
	# _on_status_applied lifts the body then.
	_base_animation = _idle()
	_play(_base_animation)


## Warns about every clip name referenced by this unit's own animation
## fields, or anywhere in its body's MotionSet, that doesn't actually exist
## on animation_player — checked once here at scene load rather than
## only discovered lazily whenever a specific phase is finally reached
## in play (see _play()'s own warning for that backstop case). The
## whole point of AnimationSequence/AnimationPhase being data an author
## edits directly is undermined if a typo'd clip name just produces a
## silently frozen character with nothing in the console pointing at
## why — this is what actually makes that authoring safe.
##
## Callers (abilities, attack rows, weapons, statuses) name motion keys,
## not clips, so the motion set is the whole of what can be misspelled. A
## key the set doesn't answer is a supported "this body doesn't do that".
func _validate_animation_names() -> void:
	# A body with NO clips at all is a whitebox, and that is a supported
	# state rather than a broken one — every ability's sequence would
	# report every phase, several warnings per unit per spawn, and warning
	# noise is precisely what hides the real ones. A body that HAS a
	# library and is missing one clip from it still reports, because that
	# genuinely is a mistake.
	if animation_player.get_animation_list().is_empty():
		return

	_check_clip(idle_animation, "idle_animation")
	_check_clip(walk_animation, "walk_animation")
	_check_clip(fly_idle_animation, "fly_idle_animation")
	_check_clip(fly_move_animation, "fly_move_animation")
	_check_clip(takeoff_animation, "takeoff_animation")
	_check_clip(land_animation, "land_animation")
	_check_clip(hit_animation, "hit_animation")
	_check_clip(death_animation, "death_animation")
	if _motions:
		for key in _motions.sequences:
			_check_sequence(_motions.sequences[key], "motion \"%s\"" % key)
		for key in _motions.clips:
			_check_clip(_motions.clips[key], "motion \"%s\"" % key)



func _check_sequence(sequence: AnimationSequence, label: String) -> void:
	if not sequence:
		return
	for i in sequence.phases.size():
		var phase: AnimationPhase = sequence.phases[i]
		if phase:
			_check_clip(phase.animation_name, "%s phase %d (%s)" % [label, i, phase.animation_name])


func _check_clip(anim_name: String, label: String) -> void:
	if anim_name != "" and not animation_player.has_animation(anim_name):
		push_warning("unit_animator.gd: %s on %s references unknown animation \"%s\"." % [label, unit.name, anim_name])


## Starting a NEW move deliberately abandons any pose currently being
## held (see Unit.posed_status) — matches the already-agreed rule that
## a unit choosing to act while afflicted interrupts the pose rather
## than it persisting through everything. Clearing here (not just
## overwriting the clip) is what stops _on_status_removed from later
## trying to play a recovery animation for a pose the unit already
## visually got up out of by walking away.
func _on_movement_started(_u: Unit) -> void:
	if _cutscene_claimed:
		return
	unit.posed_status = null
	_posed_clip = ""
	unit.visual_state = Unit.VisualState.STANDING
	_base_animation = _idle()
	_play(_walk())


## Does NOT touch idle_animation while a pose is being held — this is
## the actual fix for "movement breaks the animation": a unit that
## slips mid-route (see _on_status_applied) is still walking the SAME
## already-in-flight move when it finishes moments later, and this used
## to unconditionally stomp the fall pose with Idle right then, well
## before the status was ever actually removed. Now it just leaves
## whatever's currently held alone; _on_status_removed is what's
## actually responsible for transitioning off it.
func _on_movement_finished(_u: Unit) -> void:
	if _cutscene_claimed:
		return
	if unit.posed_status:
		return
	_play(_idle())


## Mirrors unit_sfx.gd's/unit_vfx.gd's own _on_ability_armed exactly —
## same AbilityManager.armed_unit guard (the signal is global, this only
## reacts when THIS unit is the one arming or disarming).
##
## Doesn't touch unit.posed_status/visual_state at all — same choice
## _on_ability_use_started already makes for cast animation (see that
## method): _play() switches the visible clip regardless, and leaving
## the pose state untouched is what lets _rest_on_base_animation()
## correctly resume the held pose afterward instead of needing its own
## separate interrupt/resume bookkeeping.
func _on_ability_armed(ability: Ability) -> void:
	if _cutscene_claimed:
		return
	if AbilityManager.armed_unit != unit:
		return

	_pending_armed_enter_clip = ""
	_pending_armed_hold = ""

	if not ability:
		_put_stance_away()
		return

	var enter: String = _armed_clip(&"armed.enter", ability.armed_motion)
	var hold: String = _armed_clip(&"armed.hold", ability.armed_motion)
	_armed_stance_clips = [enter, hold]
	_armed_exit_clip = _armed_clip(&"armed.exit", ability.armed_motion)

	if enter != "" and _play(enter, stance_blend_time):
		_pending_armed_enter_clip = enter
		_pending_armed_hold = hold
		return

	# Either there is no enter clip, or it could not start — and in that
	# second case the finish that was supposed to begin the hold is never
	# coming. Either way the hold is what should be on screen now.
	_pending_armed_enter_clip = ""
	_pending_armed_hold = ""
	if hold != "":
		_play(hold, stance_blend_time)


## Disarmed. If the stance is still on screen, the exit clip lowers it (its
## finish then rests on the base like any one-shot); with no exit clip it
## goes straight back to the base. If something else has since taken the
## player - the cast that caused this disarm, a hit, a walk - that clip
## already left the stance behind and is left to finish.
func _put_stance_away() -> void:
	var showing: bool = animation_player.current_animation != "" \
		and String(animation_player.current_animation) in _armed_stance_clips
	var exit: String = _armed_exit_clip
	_armed_stance_clips = []
	_armed_exit_clip = ""
	if not showing or unit.is_moving():
		return
	if not _play(exit, stance_blend_time):
		_rest_on_base_animation()


## Fires the instant an ability use is confirmed to happen — before
## to-hit is even rolled, so this doesn't need to check result.busy/
## already_acted/in_range the way the old ability_used-based version
## did; ability_use_started only ever fires once those have already
## passed. This is what makes the animation start playing WHEN the
## attack actually begins, rather than only after the outcome (hit,
## miss, damage) is already known.
##
## Launching ANY ability ends the armed-enter/hold state, same as
## unit_sfx.gd/unit_vfx.gd's own _on_ability_use_started already does
## for their own hold moments — regardless of whether it was
## specifically the armed ability that fired.
##
## Nothing to show means nothing to wait for: an ability that plays no
## cast animation releases at once.
func _on_ability_use_started(_attacker: Unit, _target, ability: Ability) -> void:
	var action: AbilityAction = unit.current_action
	if _cutscene_claimed:
		if action:
			action.release()
		return
	_pending_armed_enter_clip = ""
	_pending_armed_hold = ""
	if not ability.plays_cast_animation:
		if action:
			action.release()
		return
	var sequence: AnimationSequence = _sequence_for(ability.motion)
	# Launched out of the stance: blend from wherever the hold loop is.
	var from_stance: bool = String(animation_player.current_animation) in _armed_stance_clips
	_play_sequence(sequence, stance_blend_time if from_stance else phase_blend_time, action)
	if ability.uses_attack_action and _active_sequence:
		_hold_busy()


## A Call Method key in the playing clip (see CharacterModel.moment).
## "release" lets the next shot go — a rapid-fire clip has one per
## round; "impact" lands the next one, through the same
## Unit.notify_impact() an ImpactSignalStep uses.
func _on_model_moment(moment_name: StringName) -> void:
	match moment_name:
		&"release":
			if _cast_action:
				_cast_action.release_next()
		&"impact":
			unit.notify_impact()


## Lets every shot the clip still held go, and lets go of the action.
func _release_cast() -> void:
	var action := _cast_action
	_cast_action = null
	if action:
		action.release_all()


func _hold_busy() -> void:
	if _holding_busy:
		return
	_holding_busy = true
	_hold_token += 1
	unit.begin_busy()
	var token := _hold_token
	get_tree().create_timer(MAX_HOLD).timeout.connect(func(): _end_hold_if(token))


## Ends the hold after `gap` seconds, unless a newer one replaced it.
func _end_hold(gap: float = 0.0) -> void:
	if not _holding_busy:
		return
	var token := _hold_token
	if gap <= 0.0:
		_end_hold_if(token)
	else:
		get_tree().create_timer(gap).timeout.connect(func(): _end_hold_if(token))


func _end_hold_if(token: int) -> void:
	if not _holding_busy or token != _hold_token:
		return
	_holding_busy = false
	_hold_token += 1
	unit.end_busy()


## Reads the currently-held status's own hit_reaction_motion if it
## set one (see StatusEffect), otherwise the animator's normal default —
## this is the ONLY thing that varies per status; whether the unit
## actually returns to its pose afterward doesn't depend on this choice
## at all, see _on_animation_finished's fallback.
func _on_took_damage(_u: Unit, _amount: int) -> void:
	if _cutscene_claimed:
		return
	if not unit.is_alive():
		return

	# The hit clip replaces the wind-up, and with it the release key the
	# wind-up was going to reach: let the cast go now.
	_release_cast()
	_end_hold()
	var posed: StatusEffect = unit.posed_status
	var reaction: String = _clip(posed.hit_reaction_motion) if posed else ""
	if reaction == "" and _aloft:
		reaction = _clip(&"hit.air")
	_play(reaction if reaction != "" else hit_animation)


func _on_died(_u: Unit) -> void:
	_release_cast()
	_end_hold()
	_active_sequence = null
	_active_phase_index = -1
	_pending_armed_enter_clip = ""
	_pending_armed_hold = ""
	_armed_stance_clips = []
	_armed_exit_clip = ""
	unit.posed_status = null
	_posed_clip = ""
	unit.visual_state = Unit.VisualState.STANDING
	_play(death_animation)


## Interrupted by anything else this unit does next (walking, attacking
## — the same as any other one-shot clip already gets interrupted) since
## this ruleset's own status behaviors (ProneBehavior, notably) don't
## prevent acting while afflicted — a unit can absolutely stand up mid-
## Grease to swing at something. That's a deliberate simplification, not
## an oversight: it means the pose doesn't automatically resume once
## they stop moving/attacking again, even if the status is technically
## still active. Good enough for a cosmetic pose; revisit only if a
## status's visual needs to survive the unit taking other actions.
func _on_status_applied(_affected_unit: Unit, effect: StatusEffect) -> void:
	if not _aloft and unit.is_flying():
		_lift_without_takeoff()
	# A body with no clip for the pose doesn't take it: nothing to hold.
	var pose: String = _clip(effect.apply_motion)
	if pose == "":
		return
	if unit.posed_status != null:
		return  # already holding a different pose — see Unit.posed_status's doc comment
	unit.posed_status = effect
	unit.visual_state = Unit.VisualState.POSED
	_posed_clip = pose
	_base_animation = pose
	_play(pose)


func _on_status_removed(_affected_unit: Unit, effect: StatusEffect) -> void:
	# A dead unit's statuses coming off is no recovery — keep the death clip.
	if effect != unit.posed_status or not unit.is_alive():
		return
	unit.posed_status = null
	_posed_clip = ""
	unit.visual_state = Unit.VisualState.STANDING
	_base_animation = _idle()
	_posed_clip = ""
	var recovery: String = _clip(effect.remove_motion)
	_play(recovery if recovery != "" else _base_animation)


func _on_unit_became_idle() -> void:
	advance_external()


## --- Flight ---

## On the ground with a weapon drawn, its stance is the idle: every
## one-shot - an attack, a hit, a reload - comes back to the guard, not
## to standing upright with the weapon hanging.
func _idle() -> String:
	if _aloft and fly_idle_animation != "":
		return fly_idle_animation
	var stance: String = _clip(_stance) if not _aloft else ""
	if stance != "" and animation_player.has_animation(stance):
		return stance
	return idle_animation


## What's in the hands changed. A unit standing idle shifts into the new
## stance at once; anything else playing (a walk, an attack, a held pose)
## comes back to it when it ends.
func _on_stance_changed(stance: StringName) -> void:
	var was_idle: String = _idle()
	_stance = stance
	if _cutscene_claimed or unit.posed_status or not unit.is_alive():
		return
	if _base_animation == was_idle:
		_base_animation = _idle()
	var showing_idle: bool = String(animation_player.current_animation) == was_idle
	if showing_idle and was_idle != _idle() and not unit.is_moving() and _active_sequence == null:
		_play(_idle(), stance_blend_time)


## What the ladder is showing: 1 climbing up, -1 down, 2 over the top
## edge, -2 getting on there, 0 not climbing.
var _climb_shown: int = 0


## A climb is part of a move, so movement_started has already played the
## walk; this swaps it for the climb on the rungs and back for the level
## steps on and off. Polled because the route crosses onto the ladder
## with no signal of its own.
func _physics_process(delta: float) -> void:
	if unit == null or _cutscene_claimed or unit.posed_status or not unit.is_alive():
		return
	_show_turning(delta)
	var over: int = unit.climbing_over()
	var over_clip: String = climb_off_animation if over > 0 else climb_on_animation
	var shown: int = unit.climb_direction()
	if over != 0:
		shown = 2 * over if animation_player.has_animation(over_clip) else over
	if shown == _climb_shown:
		return
	_climb_shown = shown
	if shown == 0:
		if unit.is_moving():
			_play(_walk(), 0.15)
		return
	if absi(shown) == 2:
		var over_seconds: float = maxf(unit.climb_over_seconds(), 0.01)
		animation_player.play(over_clip, 0.1, animation_player.get_animation(over_clip).length / over_seconds)
		return
	if climb_animation == "" or not animation_player.has_animation(climb_animation):
		return
	# One cycle climbs `rise`, so this rate keeps the hands and feet on
	# the rungs at the unit's own climb speed; phased from the stop at the
	# top so a cycle ends exactly where the clip over the edge begins.
	var clip: Animation = animation_player.get_animation(climb_animation)
	var rise: float = clip.get_meta("rise", 0.3)
	var rate: float = unit.climb_speed() * clip.length / rise
	var phase: float = fposmod((unit.global_position.y - unit.climb_stop_height()) / rise, 1.0)
	animation_player.play(climb_animation, 0.15, rate * shown)
	animation_player.seek(phase * clip.length, true)


## Faster than this starts a turn, and slower than this ends one, in radians
## a second.
const TURN_START_RATE := 1.0
const TURN_STOP_RATE := 0.3
## How long the last step of a turn still counts. Facing is mostly written on
## render frames and this runs on physics ticks, so at a low frame rate
## several ticks go by between steps of one continuous turn.
const TURN_HOLD := 0.1

var _turn_rate: float = 0.0
var _turn_held: float = 0.0


func _on_facing_swung(rate: float) -> void:
	_turn_rate = rate
	_turn_held = TURN_HOLD


## Standing still and swinging round steps the feet, for a body with turn
## clips. The clips loop and leave at once when the turn stops; anything else
## that starts playing has already replaced them.
func _show_turning(delta: float) -> void:
	_turn_held -= delta
	var rate: float = _turn_rate if _turn_held > 0.0 else 0.0
	var left: String = _clip(&"turn.left")
	var right: String = _clip(&"turn.right")
	if left == "" or right == "":
		return
	var playing: String = String(animation_player.current_animation)
	var turning: bool = playing == left or playing == right
	if unit.is_moving() or _aloft or _active_sequence != null or not (turning or playing == _idle()):
		# Or the last step of a walk would read as a turn once it stops.
		_turn_held = 0.0
		return
	if absf(rate) >= (TURN_STOP_RATE if turning else TURN_START_RATE):
		var clip: String = left if rate > 0.0 else right
		if playing != clip:
			_play(clip, 0.15)
	elif turning:
		_play(_idle(), 0.2)


func _walk() -> String:
	return fly_move_animation if _aloft and fly_move_animation != "" else walk_animation


## None of these touch a dead unit: a body that dies in the air still
## comes down, and the landing must not stand it back up.
##
## Takeoff replaces whatever the ability's cast sequence was doing: the
## lift IS the cast. The sequence is dropped rather than left to advance,
## or a timer phase of it would fire mid-climb and take the clip back.
func _on_took_off(_u: Unit) -> void:
	_aloft = true
	if _cutscene_claimed or unit.posed_status or not unit.is_alive():
		return
	_abandon_sequence()
	_base_animation = _idle()
	if not _play(takeoff_animation):
		_play(_base_animation)


func _on_touched_down(_u: Unit) -> void:
	_aloft = false
	if _cutscene_claimed or unit.posed_status or not unit.is_alive():
		return
	_abandon_sequence()
	_base_animation = _idle()
	if not _play(land_animation):
		_play(_base_animation)


## Already flying with no takeoff to show for it. Swaps the ground idle
## for the flying one if that is what's showing, and nothing else.
func _lift_without_takeoff() -> void:
	var ground_idle: String = _idle()
	_aloft = true
	if _cutscene_claimed or unit.posed_status or not unit.is_alive():
		return
	var was_idle: bool = _base_animation == ground_idle
	_base_animation = _idle()
	if was_idle and animation_player.current_animation == ground_idle:
		_play(_base_animation)


func _abandon_sequence() -> void:
	_release_cast()
	_end_hold()
	_sequence_token += 1
	_external_advance_pending = false
	_active_sequence = null
	_active_phase_index = -1


## Sequences the cast-animation phase player by chaining off each
## phase's own AdvanceTrigger (see _advance_to_next_phase), and returns
## to _base_animation after any other one-shot clip finishes — except
## death, which stays on its final pose, and except while a walk is
## genuinely still in progress (movement_finished already owns returning
## to idle for that case; forcing it here would visually interrupt an
## in-progress walk).
##
## Returning to _base_animation (not a hardcoded idle_animation) here is
## the actual fix for the pose/hit-reaction bug Unit.VisualState's doc
## comment describes: a hit reaction played while unit.visual_state ==
## POSED is a one-shot clip exactly like a cast sequence's last phase,
## and this is the SAME fallback every one-shot already funnels through
## — it just needed to ask "what should I rest on" instead of assuming
## standing idle.
func _on_animation_finished(anim_name: StringName) -> void:
	if anim_name == death_animation:
		return

	# Holds on the pose's final frame instead of falling through below —
	# see Unit.posed_status's doc comment. Cleared by _on_status_removed,
	# which is what actually plays the recovery clip
	# (StatusEffect.remove_motion) once the status is gone.
	if unit.posed_status and _posed_clip != "" and anim_name == _posed_clip:
		return

	# The armed-enter clip finishing is what starts the hold loop — see
	# _on_ability_armed. Guarded on anim_name actually matching (not
	# just _pending_armed_enter_clip being non-empty) so an unrelated
	# clip finishing mid-enter — a hit reaction interrupting it, say —
	# can't be misread as the enter clip having completed.
	if _pending_armed_enter_clip != "" and anim_name == _pending_armed_enter_clip:
		var hold: String = _pending_armed_hold
		_pending_armed_enter_clip = ""
		_pending_armed_hold = ""
		if hold != "":
			_play(hold)
		elif not unit.is_moving():
			_rest_on_base_animation()
		return

	var blend := -1.0
	var phase: AnimationPhase = _active_phase()
	if phase and anim_name == phase.animation_name:
		if phase.advance_trigger == AnimationPhase.AdvanceTrigger.ON_FINISH:
			if _advance_to_next_phase(phase_blend_time):
				return
			blend = phase_blend_time
			# last phase just finished — fall through to the same
			# rest-on-base check below, same as any other one-shot clip
			# finishing with nothing queued after it.
		elif phase.advance_trigger == AnimationPhase.AdvanceTrigger.EXTERNAL 				or phase.advance_trigger == AnimationPhase.AdvanceTrigger.ON_CAST_VFX:
			# An EXTERNAL phase's own clip reaching its natural end is NOT
			# permission to move on — only advance_external() is. But
			# unlike ON_FINISH, that's not permission to do anything else
			# either: just return and leave it alone. A finished,
			# non-looping AnimationPlayer clip (Jump's mid-air "Jump"
			# clip, confirmed non-looping — nothing in
			# UAL1_Standard.glb.import overrides its loop mode) already
			# holds cleanly on its own last frame on its own; Godot
			# simply stops advancing playback position, nothing resets
			# or changes the applied pose. Falling through to
			# _rest_on_base_animation() below (the original bug) swaps
			# it for idle mid-air; explicitly replaying it from frame 0
			# (a fix tried and reverted) is a visible pop back to its
			# start pose every time it naturally finishes. Doing nothing
			# is the only one of the three that's actually seamless.
			return

	if not unit.is_moving():
		_rest_on_base_animation(blend)


## Returning to a plain idle is a normal fresh play. Returning to a HELD
## POSE is different by default — that clip already played once in full
## when the status was first applied (see _on_status_applied) and is
## meant to be RESTING on its final frame, not replayed from the start
## every time a one-shot on top of it (a hit reaction) finishes: an
## unconditional _play(_base_animation) would visibly replay the whole
## "collapse to the ground" motion after every single hit while down,
## instead of snapping straight back to already being down. A pose clip
## authored as a genuine LOOP instead (a "lying down, breathing" idle)
## says so in its own loop mode, and this lets it keep playing normally
## rather than freezing it mid-loop, which would look wrong the other way
## around.
func _rest_on_base_animation(blend: float = -1.0) -> void:
	_play(_base_animation, blend)
	if unit.posed_status and _posed_clip != "" and _base_animation == _posed_clip \
			and animation_player.has_animation(_posed_clip) \
			and animation_player.get_animation(_posed_clip).loop_mode == Animation.LOOP_NONE:
		animation_player.seek(animation_player.current_animation_length, true)


## Returns whether a clip actually started playing.
##
## The answer matters because two callers WAIT on animation_finished, and
## a clip that never started will never send one. Both now treat "did not
## start" as "already finished" rather than waiting forever — see
## _advance_to_next_phase and _on_ability_armed.
##
## An empty name is not an error and warns about nothing: a phase may
## legitimately carry only steps and no clip, and a body may declare no
## animations at all. Only a name that was asked for by name and could not
## be found is worth complaining about.
## --- Cutscene claim ---
##
## While a scene owns this actor, GAMEPLAY must not animate it. A hit
## reaction landing mid-performance replaces the clip out from under the
## shot, and nothing reports it — the animation simply changes and the
## scene looks wrong rather than broken.
##
## DEATH IS DELIBERATELY NOT BLOCKED. Everything else here is reactive and
## can wait; a unit that dies and keeps standing is a worse lie than a
## performance interrupted, and a scene where an actor dies has bigger
## problems than its animation.
var _cutscene_claimed: bool = false


func claim_for_cutscene() -> void:
	_release_cast()
	_end_hold()
	_cutscene_claimed = true


func release_cutscene() -> void:
	_cutscene_claimed = false


func is_claimed_for_cutscene() -> bool:
	return _cutscene_claimed


## Plays a clip AS a scene, ignoring the claim — this is the one caller the
## claim exists to protect, so it must not be blocked by it.
func play_cutscene_clip(anim_name: String) -> bool:
	_base_animation = anim_name
	return _play(anim_name)


## A one-shot motion with nothing behind it - moving a prop raises a hand
## (&"gesture"). Rests back on the base animation when it ends, as every
## one-shot does (_on_animation_finished). Refused while a cutscene owns
## the body or an ability's sequence is playing, which it would cut off.
## Returns whether it played; a body with no clip for it plays nothing.
func play_motion(motion: StringName) -> bool:
	if _cutscene_claimed or _active_sequence != null:
		return false
	return _play(_clip(motion), phase_blend_time)


## This body's sequence for `motion`, or null. Aloft it asks for the ".air"
## member first, so a body with no air version plays its usual one.
func _sequence_for(motion: StringName) -> AnimationSequence:
	if _motions == null or motion == &"":
		return null
	return _motions.sequence_for(StringName(motion + ".air") if _aloft else motion)


## This body's clip for `motion`, or "" when it has none.
func _clip(motion: StringName) -> String:
	if motion == &"" or _motions == null:
		return ""
	return _motions.clip_for(motion)


## One stage of the armed loop for `kind` (Ability.armed_motion):
## "armed.enter.charged", falling back to plain "armed.enter".
func _armed_clip(stage: StringName, kind: StringName) -> String:
	return _clip(StringName(stage + "." + kind) if kind != &"" else stage)


## `blend` is the crossfade from the current clip; -1 is the player's own
## default (none, unless a body sets one).
func _play(anim_name: String, blend: float = -1.0) -> bool:
	if anim_name == "":
		return false
	if not animation_player.has_animation(anim_name):
		push_warning("unit_animator.gd: tried to play unknown animation \"%s\" on %s." % [anim_name, unit.name])
		return false
	# The two flight loops share one wing beat: starting the other over at
	# frame 0 would cross-fade two different points in the flap.
	var from: String = String(animation_player.current_animation)
	var flight := [fly_idle_animation, fly_move_animation]
	var keep_beat: bool = from != anim_name and from in flight and anim_name in flight
	var beat: float = animation_player.current_animation_position if keep_beat else 0.0
	animation_player.play(anim_name, blend)
	if keep_beat:
		animation_player.seek(fposmod(beat, animation_player.current_animation_length), false)
	return true


## --- Cast animation phase player ---
## See AnimationSequence's own header for why this state lives here as
## plain fields instead of inside an awaited coroutine the way
## VfxEffect.play() gets away with.

func _active_phase() -> AnimationPhase:
	if not _active_sequence or _active_phase_index < 0 or _active_phase_index >= _active_sequence.phases.size():
		return null
	return _active_sequence.phases[_active_phase_index]


## `blend` crossfades into the first clip that plays; see _play.
func _play_sequence(sequence: AnimationSequence, blend: float = -1.0, action: AbilityAction = null) -> void:
	_release_cast()
	_end_hold()
	_cast_action = action
	_sequence_token += 1
	_external_advance_pending = false
	_active_sequence = sequence
	_active_phase_index = -1
	# The whole sequence can now finish inside this one call, when every
	# phase skips for want of a clip. The rest-on-base that normally
	# happens as the last clip ends therefore has to happen here too —
	# same shape as _on_timer_phase_done's own check.
	if not _advance_to_next_phase(blend) and not unit.is_moving():
		_rest_on_base_animation()


## Moves to the next phase and starts playing its clip, or clears the
## active sequence and returns false if that was the last phase — every
## call site (ON_FINISH in _on_animation_finished, the ON_TIMER
## callback below, advance_external) funnels the false case into the
## same _rest_on_base_animation() fallback every other one-shot clip
## already uses, so "sequence ended" needs no special case of its own.
##
## Landing on an EXTERNAL phase with _external_advance_pending already
## set means the physical event this phase is waiting for already
## happened (see advance_external()'s doc comment) — skip straight past
## it via a self-recursive call rather than sitting on a clip that's
## already visually stale (the unit already physically landed; showing
## the airborne loop at this point would be wrong, not just late).
func _advance_to_next_phase(blend: float = -1.0) -> bool:
	_active_phase_index += 1
	var next: AnimationPhase = _active_phase()
	if not next:
		# The fallback for a clip with no release key: the cast lets go
		# as its sequence ends.
		_release_cast()
		_end_hold(turn_gap)
		_active_sequence = null
		_active_phase_index = -1
		return false

	var started: bool = _play(next.animation_name, blend)

	match next.advance_trigger:
		AnimationPhase.AdvanceTrigger.ON_FINISH:
			# Nothing is playing, so animation_finished is never coming. A
			# phase whose clip is missing — or which carries no clip at all
			# — is already as finished as it is ever going to be.
			#
			# ON_TIMER has always had its timer and EXTERNAL its pending
			# flag; ON_FINISH, the DEFAULT trigger, had no backstop of any
			# kind. A single absent clip stranded the whole sequence, and
			# with it the turn. This is what lets a body with no animation
			# library run a sequence through instead of hanging on its
			# first phase.
			if not started:
				return _advance_to_next_phase(blend)
		AnimationPhase.AdvanceTrigger.ON_TIMER:
			var token: int = _sequence_token
			get_tree().create_timer(next.duration).timeout.connect(
				func(): _on_timer_phase_done(token),
				CONNECT_ONE_SHOT
			)
		AnimationPhase.AdvanceTrigger.EXTERNAL:
			if _external_advance_pending:
				_external_advance_pending = false
				return _advance_to_next_phase(blend)
		AnimationPhase.AdvanceTrigger.ON_CAST_VFX:
			var action := _cast_action
			if not action or action.has_finished_visuals():
				return _advance_to_next_phase(blend)
			action.visuals_done.connect(_cast_vfx_phase_done.bind(_sequence_token, _active_phase_index), CONNECT_ONE_SHOT)
	return true


## An ON_CAST_VFX phase's visuals are done. One arriving after the
## sequence moved on is stale.
func _cast_vfx_phase_done(token: int, index: int) -> void:
	if token != _sequence_token or index != _active_phase_index:
		return
	if not _advance_to_next_phase(phase_blend_time) and not unit.is_moving():
		_rest_on_base_animation(phase_blend_time)


func _on_timer_phase_done(token: int) -> void:
	if token != _sequence_token:
		return  # a newer play-through has since started; this timer is stale
	if not _advance_to_next_phase(phase_blend_time) and not unit.is_moving():
		_rest_on_base_animation(phase_blend_time)


## Whether the active sequence is currently sitting on an EXTERNAL
## phase. Because Unit.use_ability()/move_to() already refuse to start
## anything new while this unit is_busy(), only ONE async thing can ever
## be in flight per unit at a time — so "an EXTERNAL phase is active
## right now" can only ever mean THIS unit's current sequence is the one
## waiting on it, regardless of which ability it belongs to. This is the
## same disambiguation an earlier version of this file needed a
## jump-specific guard flag for, generalized for free: starting anything
## new always resets _active_sequence/_active_phase_index first (see
## _play_sequence), so a stale wait can never survive past that point.
func _is_awaiting_external() -> bool:
	var phase: AnimationPhase = _active_phase()
	return phase != null and phase.advance_trigger == AnimationPhase.AdvanceTrigger.EXTERNAL


## Called by unrelated gameplay logic (today: _on_unit_became_idle, for
## Jump's landing — fired once MoveCasterEffect's Tween physically
## completes, an event with no animation-side signal of its own at all)
## to push the active sequence past a phase that can't advance itself.
##
## The physical event this represents can arrive BEFORE the sequence has
## actually reached its EXTERNAL phase yet — confirmed real, not just a
## theoretical race: jump.tres's jump_duration originally shipped at
## 1.0s, shorter than Jump_Start's own authored clip (1.33s), so
## became_idle fired while the sequence was still sitting on Start
## (ON_FINISH), not yet Loop (EXTERNAL). Since became_idle only fires
## once per busy transition, silently no-op-ing here stranded the
## sequence on Loop forever once it DID naturally arrive there — the bug
## this fixed. Flight time is now ArcFlight.duration, by distance (0.4 s
## for a short hop), so a short jump can still land before Start ends:
## this guard is what keeps that working. Nothing enforces the order,
## and any other EXTERNAL-using sequence could hit it too, depending on
## its own clip lengths. Recording the request as pending and letting
## _advance_to_next_phase() consume it the instant it lands on an
## EXTERNAL phase makes this correct regardless of which order the two
## events actually arrive in.
func advance_external() -> void:
	if _is_awaiting_external():
		if not _advance_to_next_phase(phase_blend_time) and not unit.is_moving():
			_rest_on_base_animation(phase_blend_time)
	else:
		_external_advance_pending = true
