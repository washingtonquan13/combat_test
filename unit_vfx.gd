extends Node
## Reactive trigger for the composable VFX system (see VfxEffect/VfxStep)
## — listens to existing Unit signals and plays the appropriate
## VfxEffect sequence, same wiring pattern as unit_animator.gd. Has zero
## knowledge of what's actually IN any given sequence (particles, sound,
## a projectile, all three, in whatever order) — that's entirely up to
## whichever VfxEffect resource is assigned, either on the ability
## itself or as this script's fallback.
##
## PURELY COSMETIC AND REACTIVE — use_ability() and every
## AbilityEffect.apply() resolve entirely SYNCHRONOUSLY, so damage is
## already applied by the time this fires, before the sequence even
## starts playing. ProjectileStep makes the VISUAL flight genuinely take
## time now, which is a real improvement over everything happening at
## once — but it doesn't change WHEN gameplay damage happens, which
## still isn't gated on anything visual. A truly synced version would
## need the damage-dealing AbilityEffect itself to become async (the
## begin_busy()/end_busy() pattern MoveCasterEffect/Jump already
## established) — still a distinct, separate piece of work from this one.
##
## VfxEffect/VfxStep resources are assets YOU compose in the editor
## (.tres files referencing your own particle scenes and sound files) —
## this script only supplies the reactive wiring that plays them at the
## right moments.

@export var unit: Unit
@export var default_hit_vfx: VfxEffect
@export var default_miss_vfx: VfxEffect
@export var default_death_vfx: VfxEffect


func _ready() -> void:
	if not unit:
		push_warning("unit_vfx.gd needs `unit` assigned in the Inspector.")
		return

	unit.ability_used.connect(_on_ability_used)
	unit.died.connect(_on_died)


func _on_ability_used(attacker: Unit, target, result: Dictionary) -> void:
	if result.busy or result.already_acted or not result.in_range:
		return

	var target_position: Vector3 = _get_target_position(target, attacker)

	if result.has("to_hit") and not result.to_hit.success:
		_play(default_miss_vfx, attacker.global_position, target_position)
		return

	if result.hit:
		var ability: Ability = result.ability
		var sequence: VfxEffect = ability.impact_vfx if ability.impact_vfx else default_hit_vfx
		_play(sequence, attacker.global_position, target_position, ability)


func _on_died(dying_unit: Unit) -> void:
	_play(default_death_vfx, dying_unit.global_position, dying_unit.global_position)


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
## which would cut an in-progress Tween off along with it. ability is
## optional — only the hit path has one to pass (see SpawnParticleStep's
## radius sync); miss/death sequences don't need it.
func _play(sequence: VfxEffect, from: Vector3, to: Vector3, ability: Ability = null) -> void:
	if not sequence:
		return
	sequence.play(get_tree().current_scene, from, to, ability)
