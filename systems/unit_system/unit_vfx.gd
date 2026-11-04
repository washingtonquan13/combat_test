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
## Hold effects that ride a body point, each -> the CharacterModel.Anchor
## it rides. Still the unit's children; _process moves them onto the point,
## following its position but never the bone's turn. A finished hold stays in
## here while its extinguish animation plays, so it goes out in the hand.
var _carried := {}
## Hold effects still burning after a cast started, waiting for the cast to
## let go of them (Unit.cast_released) to play their release animation.
## The release always comes — AbilityAction times out on its own.
var _awaiting_release := []
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
	unit.cast_released.connect(_on_cast_released)
	unit.took_damage.connect(_on_took_damage)
	unit.died.connect(_on_died)
	unit.status_applied.connect(_on_status_applied)
	unit.status_ticked.connect(_on_status_ticked)
	unit.status_removed.connect(_on_status_removed)
	set_process(false)


## Mirrors unit_sfx.gd's _on_ability_armed exactly — same
## CombatManager.current_unit guard (AbilityManager is global/unit-
## agnostic, this only reacts when THIS unit is the one arming), same
## enter-then-start-hold shape.
func _on_ability_armed(ability: Ability) -> void:
	if AbilityManager.armed_unit != unit:
		return

	_stop_hold_vfx()

	if not ability:
		return  # disarmed — nothing more to play

	var enter_vfx: VfxEffect = ability.armed_enter_vfx if ability.armed_enter_vfx else default_armed_enter_vfx
	_play(enter_vfx, unit.global_position, unit.global_position, ability, unit)

	var hold_scene: PackedScene = ability.armed_hold_vfx if ability.armed_hold_vfx else default_armed_hold_vfx
	_start_hold_vfx(hold_scene, ability.armed_hold_vfx_at if ability.armed_hold_vfx else CharacterModel.Anchor.GROUND)


## Launching ANY ability ends the "holding a stance" state — see
## unit_sfx.gd's own _on_ability_use_started for why this isn't
## conditional on which ability specifically armed. The cast_vfx itself
## waits for the release (_on_cast_released). An ability with no cast
## animation has released already, inside ability_use_started, before
## this ran; the hold goes out now instead.
func _on_ability_use_started(_attacker: Unit, _target, _ability: Ability) -> void:
	var action: AbilityAction = unit.current_action
	if not action:
		_stop_hold_vfx()
		return
	_hold_until_released()
	if action.is_released():
		_let_go_all()


func _start_hold_vfx(scene: PackedScene, at: CharacterModel.Anchor) -> void:
	if not scene:
		return
	_hold_instance = scene.instantiate()
	if at != CharacterModel.Anchor.GROUND and _hold_instance is Node3D:
		_carried[_hold_instance] = at
		set_process(true)
	unit.add_child(_hold_instance)
	_process(0.0)


func _process(_delta: float) -> void:
	for instance: Node3D in _carried.keys():
		if not is_instance_valid(instance):
			_carried.erase(instance)
		elif instance.is_inside_tree():
			instance.global_position = unit.anchor(_carried[instance])
	if _carried.is_empty():
		set_process(false)


## A hold scene with an "extinguish" animation on its AnimationPlayer plays
## it on the way out (the flame closed in the fist) and is freed when it
## ends; one without is freed at once, as before. The scene still follows
## the body point while it goes out.
func _stop_hold_vfx() -> void:
	var instance := _hold_instance
	_hold_instance = null
	_go_out(instance, &"extinguish")


## Casting: a hold scene with a "release" animation keeps burning in the
## hand until the cast lets go of it (the projectile leaving), then plays
## release, so the flame held is the flame thrown. One without is stopped
## at once, as any other ending.
func _hold_until_released() -> void:
	var instance := _hold_instance
	if not _has_animation(instance, &"release"):
		_stop_hold_vfx()
		return
	_hold_instance = null
	_awaiting_release.append(instance)


## The cast lets go: the held flame plays release as the cast_vfx starts,
## both from the decided action, whatever this unit is doing by now.
func _on_cast_released(action: AbilityAction) -> void:
	_let_go_all()
	var attacker: Unit = action.attacker
	if not is_instance_valid(attacker):
		return
	var ability: Ability = action.ability
	var sequence: VfxEffect = ability.cast_vfx if ability.cast_vfx else default_cast_vfx
	_play(sequence, attacker.global_position, _get_target_position(action.target, attacker), ability, attacker)


func _let_go_all() -> void:
	for instance in _awaiting_release.duplicate():
		_let_go(instance)


func _let_go(instance) -> void:
	if not _awaiting_release.has(instance):
		return
	_awaiting_release.erase(instance)
	_go_out(instance, &"release")


## Plays the named animation if the scene has it, then frees it.
func _go_out(instance, animation: StringName) -> void:
	if not (instance and is_instance_valid(instance)):
		return
	if not _has_animation(instance, animation):
		_carried.erase(instance)
		instance.queue_free()
		return
	var player: AnimationPlayer = instance.get_node("AnimationPlayer")
	player.play(animation)
	await player.animation_finished
	_carried.erase(instance)
	if is_instance_valid(instance):
		instance.queue_free()


func _has_animation(instance, animation: StringName) -> bool:
	if not (instance and is_instance_valid(instance)):
		return false
	var player := instance.get_node_or_null("AnimationPlayer") as AnimationPlayer
	return player != null and player.has_animation(animation)


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
	if target is LineTarget:
		return target.centre()
	return attacker.global_position


## Fire-and-forget (no await) — this handler shouldn't block on however
## long the sequence takes to finish playing. context is the scene root,
## not this node — see VfxEffect.play's doc comment for why: this node
## is a child of the CASTER, which could die and be freed mid-sequence,
## which would cut an in-progress Tween off along with it.
func _play(sequence: VfxEffect, from: Vector3, to: Vector3, ability: Ability = null, caster: Unit = null) -> void:
	if not sequence:
		return
	sequence.play(WorldManager.spawn_parent(), from, to, ability, caster)
