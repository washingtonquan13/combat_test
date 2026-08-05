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
## Melee vs ranged attacks play DIFFERENT things (a single Sword_Attack
## clip vs a 4-phase Enter/Idle/Shoot/Exit spell sequence), decided by
## checking ability.targeting's type. Jump gets its own 3-phase sequence
## (Start/loop/Land), detected by checking whether the used ability's
## effects contain a MoveCasterEffect — Jump doesn't go through
## Unit.move_to() at all (see move_caster_effect.gd), so it never fires
## movement_started/movement_finished the way ordinary walking does.
##
## Worth knowing: whether damage is actually TIMED to this animation
## depends on the ability's own waits_for_impact flag (see Ability). If
## it's on, Unit.use_ability() genuinely pauses before applying effects
## until something calls unit.notify_impact() — typically an
## AnimationPlayer Call Method Track placed at the frame a weapon
## actually connects (e.g. mid-swing on sword_attack_animation). This
## script doesn't add that track for you — it has to be placed manually
## in each relevant clip in the AnimationPlayer editor, calling
## unit.notify_impact via the track's configured target. If
## waits_for_impact is off (the default), or a clip never got that
## track added, effects still resolve — either immediately, or after
## Ability.impact_timeout elapses as a safety fallback — so a missing
## track doesn't hang the turn, it just means that specific ability
## isn't actually synced yet.
##
## SETUP REQUIREMENT: the Jump loop clip (jump_loop_animation) needs to
## actually be authored/set to loop in its import/Animation settings.
## Landing is triggered by force-interrupting it via became_idle (see
## _on_unit_became_idle) regardless of whether it loops, so this isn't
## strictly required for correctness — but if it's NOT looping and
## finishes before the physical jump does, the character will visibly
## freeze on Jump's last frame until landing actually triggers Jump_Land.

@export var unit: Unit
@export var animation_player: AnimationPlayer

@export_group("Clip Names")
@export var idle_animation: String = "Idle"
@export var walk_animation: String = "Jog_Fwd"
@export var sword_attack_animation: String = "Sword_Attack"
@export var hit_animation: String = "Hit_Chest"
@export var death_animation: String = "Death01"

@export_group("Ranged/Spell Sequence")
@export var spell_enter_animation: String = "Spell_Simple_Enter"
@export var spell_idle_animation: String = "Spell_Simple_Idle"
@export var spell_shoot_animation: String = "Spell_Simple_Shoot"
@export var spell_exit_animation: String = "Spell_Simple_Exit"
## How long to hold on spell_idle_animation before firing Shoot. NOT
## driven by animation_finished like the other sequence steps —
## "Idle"-named clips are often authored to loop indefinitely (likely
## true here too, given the name), so waiting for it to finish naturally
## could mean waiting forever and never reaching Shoot at all.
@export var spell_channel_duration: float = 0.3

@export_group("Jump Sequence")
@export var jump_start_animation: String = "Jump_Start"
@export var jump_loop_animation: String = "Jump"
@export var jump_land_animation: String = "Jump_Land"

## True only while actively sequencing a jump (Start -> loop -> Land) —
## disambiguates Unit.became_idle, which fires whenever ANY async
## busy-state clears, not just a jump landing specifically. Without this,
## a future unrelated async effect finishing could be misread as "the
## jump just landed."
var _awaiting_jump_land: bool = false

## Whichever StatusEffect currently has this unit visually holding its
## apply_animation's final frame (see StatusEffect.apply_animation) —
## null when nothing's holding a pose. A single slot, not a stack:
## a unit can only physically be in one pose at once, so that's the
## right model for as long as only one status ever sets apply_animation
## at a time. If a SECOND held-pose status is ever added and both land
## on the same unit around the same time, the second is deliberately
## ignored (see _on_status_applied) rather than clobbering this — losing
## one status's pose animation is a fine trade against the alternative,
## which is a unit stuck holding a pose forever with nothing left
## tracking it to ever play its remove_animation.
var _held_status_effect: StatusEffect = null


func _ready() -> void:
	if not unit or not animation_player:
		push_warning("unit_animator.gd needs both `unit` and `animation_player` assigned in the Inspector.")
		return

	unit.movement_started.connect(_on_movement_started)
	unit.movement_finished.connect(_on_movement_finished)
	unit.ability_use_started.connect(_on_ability_use_started)
	unit.took_damage.connect(_on_took_damage)
	unit.died.connect(_on_died)
	unit.became_idle.connect(_on_unit_became_idle)
	unit.status_applied.connect(_on_status_applied)
	unit.status_removed.connect(_on_status_removed)
	animation_player.animation_finished.connect(_on_animation_finished)

	_play(idle_animation)


## Starting a NEW move deliberately abandons any pose currently being
## held (see _held_status_effect) — matches the already-agreed rule that
## a unit choosing to act while afflicted interrupts the pose rather
## than it persisting through everything. Clearing here (not just
## overwriting the clip) is what stops _on_status_removed from later
## trying to play a recovery animation for a pose the unit already
## visually got up out of by walking away.
func _on_movement_started(_u: Unit) -> void:
	_held_status_effect = null
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
	if _held_status_effect:
		return
	_play(idle_animation)


## Fires the instant an ability use is confirmed to happen — before
## to-hit is even rolled, so this doesn't need to check result.busy/
## already_acted/in_range the way the old ability_used-based version
## did; ability_use_started only ever fires once those have already
## passed. This is what makes the animation start playing WHEN the
## attack actually begins, rather than only after the outcome (hit,
## miss, damage) is already known.
func _on_ability_use_started(_attacker: Unit, _target, ability: Ability) -> void:
	if _is_jump(ability):
		_start_jump_sequence()
		return

	if ability.targeting is MeleeEnemyTargeting:
		_play(sword_attack_animation)
	else:
		_start_spell_sequence()


func _is_jump(ability: Ability) -> bool:
	for effect in ability.effects:
		if effect is MoveCasterEffect:
			return true
	return false


func _start_jump_sequence() -> void:
	_awaiting_jump_land = true
	_play(jump_start_animation)
	# Jump loop starts once Jump_Start finishes naturally (see
	# _on_animation_finished). Landing is triggered by
	# Unit.became_idle, not by waiting on the loop clip — that fires
	# exactly when MoveCasterEffect's tween completes, i.e. the actual
	# physical moment the arc reaches its destination, regardless of
	# whatever the loop clip itself is doing.


func _start_spell_sequence() -> void:
	_play(spell_enter_animation)
	# Idle -> (timed hold) -> Shoot -> Exit, sequenced in
	# _on_animation_finished / _on_spell_channel_done.


func _on_took_damage(_u: Unit, _amount: int) -> void:
	if unit.is_alive():
		_play(hit_animation)


func _on_died(_u: Unit) -> void:
	_awaiting_jump_land = false
	_held_status_effect = null
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
	if _held_status_effect != null:
		return  # already holding a different pose — see _held_status_effect's doc comment
	_held_status_effect = effect
	_play(effect.apply_animation)


func _on_status_removed(_affected_unit: Unit, effect: StatusEffect) -> void:
	if effect != _held_status_effect:
		return
	_held_status_effect = null
	if effect.remove_animation != "":
		_play(effect.remove_animation)


func _on_unit_became_idle() -> void:
	if not _awaiting_jump_land:
		return
	_awaiting_jump_land = false
	_play(jump_land_animation)


func _on_spell_channel_done() -> void:
	_play(spell_shoot_animation)


## Sequences the multi-clip jump/spell sequences by chaining off each
## clip's natural completion (except the deliberately-timer-driven
## spell-idle step — see spell_channel_duration), and returns to idle
## after any other one-shot clip finishes — except death, which stays on
## its final pose, and except while a walk is genuinely still in
## progress (movement_finished already owns returning to idle for that
## case; forcing it here would visually interrupt an in-progress walk).
func _on_animation_finished(anim_name: StringName) -> void:
	if anim_name == death_animation:
		return

	# Holds on the pose's final frame instead of falling through to idle
	# below — see _held_status_effect's doc comment. Cleared by
	# _on_status_removed, which is what actually plays the recovery clip
	# (StatusEffect.remove_animation) once the status is gone.
	if _held_status_effect and anim_name == _held_status_effect.apply_animation:
		return

	if anim_name == jump_start_animation:
		_play(jump_loop_animation)
		return

	if anim_name == spell_enter_animation:
		_play(spell_idle_animation)
		get_tree().create_timer(spell_channel_duration).timeout.connect(_on_spell_channel_done, CONNECT_ONE_SHOT)
		return
	if anim_name == spell_shoot_animation:
		_play(spell_exit_animation)
		return

	if not unit.is_moving():
		_play(idle_animation)


func _play(anim_name: String) -> void:
	if animation_player.has_animation(anim_name):
		animation_player.play(anim_name)
