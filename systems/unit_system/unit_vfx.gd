extends Node
## Reactive trigger for the composable VFX system (see VfxEffect/VfxStep)
## — listens to Unit signals and plays the appropriate VfxEffect
## sequence, same wiring pattern as unit_animator.gd. Has zero knowledge
## of what's actually IN any given sequence (particles, sound, a
## projectile, all three, in whatever order) — that's entirely up to
## whichever VfxEffect resource is assigned, either on the ability
## itself or as this script's fallback.
##
## Listens to ability_use_started, not ability_used — the sequence needs
## to begin the INSTANT an ability is confirmed to happen (so a
## projectile can actually fly), not wait for the final to-hit outcome,
## which isn't even known yet at that point. This means the cast
## sequence plays THE SAME WAY regardless of whether the attack will
## eventually be ruled a hit or miss — there's deliberately no separate
## "miss" VFX anymore (an earlier version of this script had one, keyed
## off the final result — that's no longer possible at the moment this
## needs to react). Whether damage actually applies at the end of the
## sequence depends entirely on the ability's own to-hit roll and
## waits_for_impact setting (see Ability, and UnitCombat.use_ability) —
## this script has no involvement in that at all, it only ever plays
## what things LOOK like, never decides what they DO.
##
## If the sequence contains an ImpactSignalStep, that step calling
## Unit.notify_impact() is what actually unblocks use_ability() to apply
## effects, for any ability with waits_for_impact on — see that class's
## header. Without one, a waits_for_impact ability just falls back to
## its timeout instead of ever syncing to this sequence at all.
##
## Also owns the armed-enter/armed-hold moments (see _on_ability_armed
## below) — the VFX counterpart to unit_sfx.gd's existing armed-enter/
## armed-hold SFX handling, filtered the same way (AbilityManager is
## global/unit-agnostic; this only reacts when THIS unit is the one
## arming).
##
## VfxEffect/VfxStep resources, and armed-hold PackedScenes, are assets
## YOU compose in the editor (.tres/.tscn files referencing your own
## particle scenes and sound files) — this script only supplies the
## reactive wiring that plays them at the right moments.

@export var unit: Unit
@export var default_armed_enter_vfx: VfxEffect
## A looping/continuous scene to instantiate and hold for as long as an
## ability stays armed — deliberately a bare PackedScene, not a
## composable VfxEffect sequence, mirroring why unit_sfx.gd's
## armed_hold_sfx is a bare AudioStream rather than an SfxCue: a
## sustained effect that's meant to keep running indefinitely doesn't
## fit VfxStep's contract of eventually finishing (VfxEffect.play()
## awaits every step to completion) — this is instantiated and simply
## never forced into one-shot mode, the same "the asset itself loops,
## calling code just holds and releases it" shape armed_hold_sfx uses.
@export var default_armed_hold_vfx: PackedScene
@export var default_cast_vfx: VfxEffect
@export var default_death_vfx: VfxEffect

## Instantiated and simply held — not awaited, not forced into one-shot
## mode, so a looping scene keeps looping until _stop_hold_vfx() frees
## it. Parented directly under `unit` (not the scene root, unlike the
## one-shot _play() sequences) — deliberately: this represents THIS
## unit's own "armed, waiting to act" state, which should end the
## instant they die, same as unit_sfx.gd's own _hold_player. One-shot
## VfxEffect sequences use the scene root instead specifically so an
## in-flight fireball can finish even if its caster died right after
## casting — that reasoning doesn't apply to a hold effect, there's
## nothing left to finish once the unit holding the stance is gone.
var _hold_instance: Node = null
## Played instead of nothing at all when this unit takes damage while
## visual_state == POSED (see Unit.visual_state) and the held status
## doesn't set its own StatusEffect.hit_reaction_vfx — left unset (the
## default), a hit taken while posed simply gets no extra VFX of its own,
## same as a standing hit already gets none from this script today.
@export var default_hit_reaction_vfx: VfxEffect


func _ready() -> void:
	if not unit:
		push_warning("unit_vfx.gd needs `unit` assigned in the Inspector.")
		return

	AbilityManager.ability_armed.connect(_on_ability_armed)
	unit.ability_use_started.connect(_on_ability_use_started)
	unit.took_damage.connect(_on_took_damage)
	unit.died.connect(_on_died)
	unit.status_applied.connect(_on_status_applied)
	unit.status_ticked.connect(_on_status_ticked)
	unit.status_removed.connect(_on_status_removed)


## Mirrors unit_sfx.gd's _on_ability_armed exactly — same
## CombatManager.current_unit guard (AbilityManager is global/unit-
## agnostic, this only reacts when THIS unit is the one arming), same
## enter-then-start-hold shape.
func _on_ability_armed(ability: Ability) -> void:
	if CombatManager.current_unit != unit:
		return

	_stop_hold_vfx()

	if not ability:
		return  # disarmed — nothing more to play

	var enter_vfx: VfxEffect = ability.armed_enter_vfx if ability.armed_enter_vfx else default_armed_enter_vfx
	_play(enter_vfx, unit.global_position, unit.global_position, ability, unit)

	var hold_scene: PackedScene = ability.armed_hold_vfx if ability.armed_hold_vfx else default_armed_hold_vfx
	_start_hold_vfx(hold_scene)


## Launching ANY ability ends the "holding a stance" state — see
## unit_sfx.gd's own _on_ability_use_started for why this isn't
## conditional on which ability specifically armed.
func _on_ability_use_started(attacker: Unit, target, ability: Ability) -> void:
	_stop_hold_vfx()

	var target_position: Vector3 = _get_target_position(target, attacker)
	var sequence: VfxEffect = ability.cast_vfx if ability.cast_vfx else default_cast_vfx
	_play(sequence, attacker.global_position, target_position, ability, attacker)


func _start_hold_vfx(scene: PackedScene) -> void:
	if not scene:
		return
	_hold_instance = scene.instantiate()
	unit.add_child(_hold_instance)


func _stop_hold_vfx() -> void:
	if _hold_instance and is_instance_valid(_hold_instance):
		_hold_instance.queue_free()
	_hold_instance = null


## Reads the currently-held status's own hit_reaction_vfx if it set one
## (see StatusEffect), otherwise this script's own default — same
## pattern as unit_animator.gd's _on_took_damage, reading the SAME
## Unit.posed_status rather than tracking pose state independently here.
func _on_took_damage(hit_unit: Unit, _amount: int) -> void:
	if not hit_unit.is_alive():
		return

	var posed: StatusEffect = hit_unit.posed_status
	var sequence: VfxEffect = posed.hit_reaction_vfx if posed and posed.hit_reaction_vfx else default_hit_reaction_vfx
	_play(sequence, hit_unit.global_position, hit_unit.global_position)


func _on_died(dying_unit: Unit) -> void:
	_play(default_death_vfx, dying_unit.global_position, dying_unit.global_position)


## Status VFX is self-targeted (the affected unit, not a caster/target
## pair) — from and to are both this unit's own position, and ability/
## caster are left null since a status tick has no ability context of
## its own (see StatusEffect's Apply/Tick/Remove FX groups).
func _on_status_applied(affected_unit: Unit, effect: StatusEffect) -> void:
	_play(effect.apply_vfx, affected_unit.global_position, affected_unit.global_position)


func _on_status_ticked(affected_unit: Unit, effect: StatusEffect) -> void:
	_play(effect.tick_vfx, affected_unit.global_position, affected_unit.global_position)


func _on_status_removed(affected_unit: Unit, effect: StatusEffect) -> void:
	_play(effect.remove_vfx, affected_unit.global_position, affected_unit.global_position)


func _get_target_position(target, attacker: Unit) -> Vector3:
	if target is Unit:
		return target.global_position
	if target is Vector3:
		return target
	return attacker.global_position


## Fire-and-forget (no await) — this handler shouldn't block on however
## long the sequence takes to finish playing. context is the scene root,
## not this node — see VfxEffect.play's doc comment for why: this node
## is a child of the CASTER, which could die and be freed mid-sequence,
## which would cut an in-progress Tween off along with it.
func _play(sequence: VfxEffect, from: Vector3, to: Vector3, ability: Ability = null, caster: Unit = null) -> void:
	if not sequence:
		return
	sequence.play(get_tree().current_scene, from, to, ability, caster)
