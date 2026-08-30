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
## An ability's cast animation is driven entirely by data (see
## AnimationSequence/AnimationPhase) rather than hardcoded per ability
## shape — this script has no idea what a "melee attack," "spell," or
## "jump" is anymore. ability.cast_animation (falling back to this
## script's own default_cast_animation when unset, same fallback shape
## cast_vfx/cast_sfx already use) supplies an ordered list of phases;
## this script just plays each phase's clip and advances to the next one
## whenever that phase's own AdvanceTrigger says to — see
## _advance_to_next_phase()/_active_phase() near the bottom of this file
## for the actual player.
##
## Worth knowing: whether damage is actually TIMED to this animation
## depends on the ability's own waits_for_impact flag (see Ability). If
## it's on, Unit.use_ability() genuinely pauses before applying effects
## until something calls unit.notify_impact() — typically an
## AnimationPlayer Call Method Track placed at the frame a weapon
## actually connects (e.g. mid-swing on whichever clip a melee ability's
## cast_animation plays). This script doesn't add that track for you —
## it has to be placed manually in each relevant clip in the
## AnimationPlayer editor, calling unit.notify_impact via the track's
## configured target. If waits_for_impact is off (the default), or a
## clip never got that track added, effects still resolve — either
## immediately, or after Ability.impact_timeout elapses as a safety
## fallback — so a missing track doesn't hang the turn, it just means
## that specific ability isn't actually synced yet.
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

@export_group("Cast Animation")
## Fallback AnimationSequence for any ability that doesn't set its own
## cast_animation — same fallback shape unit_vfx.gd/unit_sfx.gd already
## use for cast_vfx/cast_sfx.
@export var default_cast_animation: AnimationSequence

@export_group("Armed Animation")
## Fallback clip names for any ability that doesn't set its own
## armed_enter_animation/armed_hold_animation — same fallback shape
## unit_sfx.gd/unit_vfx.gd already use for their own armed moments. See
## _on_ability_armed() for how the two chain together.
@export var default_armed_enter_animation: String = ""
@export var default_armed_hold_animation: String = ""

## What a one-shot clip (a hit reaction, most commonly) returns to once
## it finishes — idle_animation normally, or the held status's
## apply_animation while unit.visual_state == POSED. The single source
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
	animation_player.animation_finished.connect(_on_animation_finished)

	_validate_animation_names()

	_base_animation = idle_animation
	_play(idle_animation)


## Warns about every clip name referenced by this unit's own animation
## fields, or by any ability in its roster, that doesn't actually exist
## on animation_player — checked once here at scene load rather than
## only discovered lazily whenever a specific phase is finally reached
## in play (see _play()'s own warning for that backstop case). The
## whole point of AnimationSequence/AnimationPhase being data an author
## edits directly is undermined if a typo'd clip name just produces a
## silently frozen character with nothing in the console pointing at
## why — this is what actually makes that authoring safe.
##
## Can't do the same for StatusEffect's own apply_animation/
## hit_reaction_animation/remove_animation fields the same way — which
## status a unit might end up carrying isn't known until one's actually
## applied at runtime, unlike abilities, which are a fixed roster
## sitting on unit.abilities from the start.
func _validate_animation_names() -> void:
	_check_clip(idle_animation, "idle_animation")
	_check_clip(walk_animation, "walk_animation")
	_check_clip(hit_animation, "hit_animation")
	_check_clip(death_animation, "death_animation")
	_check_sequence(default_cast_animation, "default_cast_animation")
	_check_clip(default_armed_enter_animation, "default_armed_enter_animation")
	_check_clip(default_armed_hold_animation, "default_armed_hold_animation")

	for ability in unit.abilities:
		if not ability:
			continue
		_check_sequence(ability.cast_animation, "%s.cast_animation" % ability.ability_name)
		_check_clip(ability.armed_enter_animation, "%s.armed_enter_animation" % ability.ability_name)
		_check_clip(ability.armed_hold_animation, "%s.armed_hold_animation" % ability.ability_name)


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
	unit.posed_status = null
	unit.visual_state = Unit.VisualState.STANDING
	_base_animation = idle_animation
	_play(walk_animation)


## Does NOT touch idle_animation while a pose is being held — this is
## the actual fix for "movement breaks the animation": a unit that
## slips mid-route (see _on_status_applied) is still walking the SAME
## already-in-flight move when it finishes moments later, and this used
## to unconditionally stomp the fall pose with Idle right then, well
## before the status was ever actually removed. Now it just leaves
## whatever's currently held alone; _on_status_removed is what's
## actually responsible for transitioning off it.
func _on_movement_finished(_u: Unit) -> void:
	if unit.posed_status:
		return
	_play(idle_animation)


## Mirrors unit_sfx.gd's/unit_vfx.gd's own _on_ability_armed exactly —
## same CombatManager.current_unit guard (AbilityManager is global/
## unit-agnostic, this only reacts when THIS unit is the one arming).
##
## Doesn't touch unit.posed_status/visual_state at all — same choice
## _on_ability_use_started already makes for cast animation (see that
## method): _play() switches the visible clip regardless, and leaving
## the pose state untouched is what lets _rest_on_base_animation()
## correctly resume the held pose afterward instead of needing its own
## separate interrupt/resume bookkeeping.
func _on_ability_armed(ability: Ability) -> void:
	if unit.in_combat() and not unit.is_my_turn():
		return

	_pending_armed_enter_clip = ""
	_pending_armed_hold = ""

	if not ability:
		# disarmed — same "what should I actually be showing right now"
		# fallback every other one-shot completion already funnels
		# through, rather than a bespoke "just play idle" special case.
		if not unit.is_moving():
			_rest_on_base_animation()
		return

	var enter: String = ability.armed_enter_animation if ability.armed_enter_animation != "" else default_armed_enter_animation
	var hold: String = ability.armed_hold_animation if ability.armed_hold_animation != "" else default_armed_hold_animation

	if enter != "":
		_pending_armed_enter_clip = enter
		_pending_armed_hold = hold
		_play(enter)
	elif hold != "":
		_play(hold)


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
func _on_ability_use_started(_attacker: Unit, _target, ability: Ability) -> void:
	_pending_armed_enter_clip = ""
	_pending_armed_hold = ""
	var sequence: AnimationSequence = ability.cast_animation if ability.cast_animation else default_cast_animation
	_play_sequence(sequence)


## Reads the currently-held status's own hit_reaction_animation if it
## set one (see StatusEffect), otherwise the animator's normal default —
## this is the ONLY thing that varies per status; whether the unit
## actually returns to its pose afterward doesn't depend on this choice
## at all, see _on_animation_finished's fallback.
func _on_took_damage(_u: Unit, _amount: int) -> void:
	if not unit.is_alive():
		return

	var posed: StatusEffect = unit.posed_status
	if posed and posed.hit_reaction_animation != "":
		_play(posed.hit_reaction_animation)
	else:
		_play(hit_animation)


func _on_died(_u: Unit) -> void:
	_active_sequence = null
	_active_phase_index = -1
	_pending_armed_enter_clip = ""
	_pending_armed_hold = ""
	unit.posed_status = null
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
	if effect.apply_animation == "":
		return
	if unit.posed_status != null:
		return  # already holding a different pose — see Unit.posed_status's doc comment
	unit.posed_status = effect
	unit.visual_state = Unit.VisualState.POSED
	_base_animation = effect.apply_animation
	_play(effect.apply_animation)


func _on_status_removed(_affected_unit: Unit, effect: StatusEffect) -> void:
	if effect != unit.posed_status:
		return
	unit.posed_status = null
	unit.visual_state = Unit.VisualState.STANDING
	_base_animation = idle_animation
	if effect.remove_animation != "":
		_play(effect.remove_animation)
	else:
		_play(idle_animation)


func _on_unit_became_idle() -> void:
	advance_external()


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
	# (StatusEffect.remove_animation) once the status is gone.
	var posed: StatusEffect = unit.posed_status
	if posed and anim_name == posed.apply_animation:
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

	var phase: AnimationPhase = _active_phase()
	if phase and anim_name == phase.animation_name:
		if phase.advance_trigger == AnimationPhase.AdvanceTrigger.ON_FINISH:
			if _advance_to_next_phase():
				return
			# last phase just finished — fall through to the same
			# rest-on-base check below, same as any other one-shot clip
			# finishing with nothing queued after it.
		elif phase.advance_trigger == AnimationPhase.AdvanceTrigger.EXTERNAL:
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
		_rest_on_base_animation()


## Returning to a plain idle is a normal fresh play. Returning to a HELD
## POSE is different by default — that clip already played once in full
## when the status was first applied (see _on_status_applied) and is
## meant to be RESTING on its final frame, not replayed from the start
## every time a one-shot on top of it (a hit reaction) finishes: an
## unconditional _play(_base_animation) would visibly replay the whole
## "collapse to the ground" motion after every single hit while down,
## instead of snapping straight back to already being down. That's the
## default (StatusEffect.apply_animation_loops == false) — a status
## whose pose is authored as a genuine LOOP instead (a "lying down,
## breathing" idle) sets that field, and this just lets it keep playing
## normally rather than freezing it mid-loop, which would look wrong the
## other way around.
func _rest_on_base_animation() -> void:
	_play(_base_animation)
	var posed: StatusEffect = unit.posed_status
	if posed and _base_animation == posed.apply_animation and not posed.apply_animation_loops:
		if animation_player.has_animation(_base_animation):
			animation_player.seek(animation_player.current_animation_length, true)


func _play(anim_name: String) -> void:
	if animation_player.has_animation(anim_name):
		animation_player.play(anim_name)
	else:
		push_warning("unit_animator.gd: tried to play unknown animation \"%s\" on %s." % [anim_name, unit.name])


## --- Cast animation phase player ---
## See AnimationSequence's own header for why this state lives here as
## plain fields instead of inside an awaited coroutine the way
## VfxEffect.play() gets away with.

func _active_phase() -> AnimationPhase:
	if not _active_sequence or _active_phase_index < 0 or _active_phase_index >= _active_sequence.phases.size():
		return null
	return _active_sequence.phases[_active_phase_index]


func _play_sequence(sequence: AnimationSequence) -> void:
	_sequence_token += 1
	_external_advance_pending = false
	_active_sequence = sequence
	_active_phase_index = -1
	_advance_to_next_phase()


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
func _advance_to_next_phase() -> bool:
	_active_phase_index += 1
	var next: AnimationPhase = _active_phase()
	if not next:
		_active_sequence = null
		_active_phase_index = -1
		return false

	_play(next.animation_name)

	match next.advance_trigger:
		AnimationPhase.AdvanceTrigger.ON_TIMER:
			var token: int = _sequence_token
			get_tree().create_timer(next.duration).timeout.connect(
				func(): _on_timer_phase_done(token),
				CONNECT_ONE_SHOT
			)
		AnimationPhase.AdvanceTrigger.EXTERNAL:
			if _external_advance_pending:
				_external_advance_pending = false
				return _advance_to_next_phase()
	return true


func _on_timer_phase_done(token: int) -> void:
	if token != _sequence_token:
		return  # a newer play-through has since started; this timer is stale
	if not _advance_to_next_phase() and not unit.is_moving():
		_rest_on_base_animation()


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
## this fixed. jump_duration is now tuned past Jump_Start's length so
## this specific case no longer triggers the race in practice, but the
## guard stays: nothing enforces that relationship, and any other
## EXTERNAL-using sequence could hit the same ordering depending on its
## own clip lengths. Recording the request as pending and letting
## _advance_to_next_phase() consume it the instant it lands on an
## EXTERNAL phase makes this correct regardless of which order the two
## events actually arrive in.
func advance_external() -> void:
	if _is_awaiting_external():
		if not _advance_to_next_phase() and not unit.is_moving():
			_rest_on_base_animation()
	else:
		_external_advance_pending = true
