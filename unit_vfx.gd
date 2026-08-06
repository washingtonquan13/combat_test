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
## which isn't even known yet at that point. This means the impact
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
## VfxEffect/VfxStep resources are assets YOU compose in the editor
## (.tres files referencing your own particle scenes and sound files) —
## this script only supplies the reactive wiring that plays them at the
## right moments.

@export var unit: Unit
@export var default_impact_vfx: VfxEffect
@export var default_death_vfx: VfxEffect
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

	unit.ability_use_started.connect(_on_ability_use_started)
	unit.took_damage.connect(_on_took_damage)
	unit.died.connect(_on_died)
	unit.status_applied.connect(_on_status_applied)
	unit.status_ticked.connect(_on_status_ticked)
	unit.status_removed.connect(_on_status_removed)


func _on_ability_use_started(attacker: Unit, target, ability: Ability) -> void:
	var target_position: Vector3 = _get_target_position(target, attacker)
	var sequence: VfxEffect = ability.impact_vfx if ability.impact_vfx else default_impact_vfx
	_play(sequence, attacker.global_position, target_position, ability, attacker)


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
