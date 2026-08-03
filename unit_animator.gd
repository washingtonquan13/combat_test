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
## Worth knowing: the spell sequence is PURELY cosmetic timing, not tied
## to when damage actually resolves — this combat system resolves an
## attack's outcome (hit/miss/damage) entirely synchronously the instant
## use_ability() is called, before any animation plays at all. The
## "Shoot" clip triggering doesn't correspond to some deeper moment of
## calculation; it's sequenced for visual flavor after the fact. Common
## and reasonable, just worth being explicit about.
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


func _ready() -> void:
	if not unit or not animation_player:
		push_warning("unit_animator.gd needs both `unit` and `animation_player` assigned in the Inspector.")
		return

	unit.movement_started.connect(_on_movement_started)
	unit.movement_finished.connect(_on_movement_finished)
	unit.ability_used.connect(_on_ability_used)
	unit.took_damage.connect(_on_took_damage)
	unit.died.connect(_on_died)
	unit.became_idle.connect(_on_unit_became_idle)
	animation_player.animation_finished.connect(_on_animation_finished)

	_play(idle_animation)


func _on_movement_started(_u: Unit) -> void:
	_play(walk_animation)


func _on_movement_finished(_u: Unit) -> void:
	_play(idle_animation)


func _on_ability_used(_attacker: Unit, _target, result: Dictionary) -> void:
	if result.busy or result.already_acted or not result.in_range:
		return

	if _is_jump(result.ability):
		_start_jump_sequence()
		return

	if result.ability.targeting is MeleeEnemyTargeting:
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
	_play(death_animation)


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
