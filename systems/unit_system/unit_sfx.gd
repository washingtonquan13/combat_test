extends Node
## Reactive SFX trigger, synced to the SAME anchors driving animation and
## VFX. Mirrors unit_animator.gd/unit_vfx.gd's exact wiring pattern:
## zero combat logic of its own, purely reactive to signals that already
## exist (or, for arming specifically, to AbilityManager's existing
## signal, filtered to whether THIS unit is the one doing the arming —
## AbilityManager itself is global/unit-agnostic, on purpose, same as
## everywhere else it's used in this project).
##
## Owns the four standard ABILITY audio moments in one place: armed-enter,
## armed-hold (a sustained loop while an ability stays armed, waiting
## for a target), cast, and impact — plus three STATUS moments (apply/
## tick/remove, see the block below on those). Cast/impact deliberately
## react directly to Unit.ability_use_started/impact_triggered — the same
## unit-level signals animation/VFX already react to — rather than
## living inside the ability's cast_vfx sequence as a PlaySoundStep.
## That used to be the recommendation; it changed after a purely visual
## fix to SpawnParticleStep's cleanup logic silently broke a
## PlaySoundStep's timing, since they shared the same sequence and
## therefore the same execution path. Reacting to the unit-level signals
## directly means a future VFX-only change can't do that again — audio
## and visuals no longer share any code path at all for these two
## moments. PlaySoundStep still exists inside VfxEffect for sounds that
## genuinely need positioning relative to a specific mid-sequence VFX
## moment with no corresponding combat signal (timed to a projectile's
## midpoint, say) — this file isn't trying to replace that, only to be
## the default home for the two common, standard moments.
##
## cast_sfx lives directly on Ability — genuinely universal, every
## ability fires ability_use_started regardless of shape. impact_sfx
## lives on the OPTIONAL Ability.timing (see AbilityTiming) instead —
## "impact" as a concept only exists for abilities with a genuinely
## distinct launch/impact shape (a projectile, a synced melee swing); a
## self-buff or passive has no such moment at all, and previously
## carried an impact_sfx field regardless, unused. Most abilities simply
## have no AbilityTiming assigned, in which case impact falls straight
## through to this script's own generic default.
##
## Armed-enter/cast/impact are each a composable SfxCue (see that
## file), not a bare AudioStream — these are exactly the kind of moment
## that often wants more than one layered sound, and a single-field
## design can't express that without growing new fields per additional
## sound. armed-hold stays a plain AudioStream — a sustained loop is a
## different enough case (layering multiple loops is a rare need) that
## the same composition wasn't worth applying there too.
##
## Deliberately NON-BLOCKING throughout — nothing here ever awaits
## anything itself (SfxCue/SfxLayer's own internal per-layer delays run
## independently in the background), matching how BG3/DOS2/WotR/PoE2
## actually handle this: combat never waits on audio length. What makes
## it feel synced is that each sound STARTS at the exact right moment,
## not that anything is gated on it finishing.
##
## Status apply/tick/remove (see status_manager.gd's status_applied/
## status_ticked/status_removed, relayed through Unit the same way as
## the ability signals above) are the status system's own equivalent of
## cast/impact — StatusEffect.apply_sfx/tick_sfx/remove_sfx, each an
## SfxCue same as the ability fields, played at the AFFECTED unit's own
## position (there's no separate attacker/target split for a status
## tick the way there is for an ability). Unlike ability moments, these
## have no default-fallback fields here — a status with none of the
## three assigned is simply silent, which is the right default for the
## many statuses (most buffs/debuffs) that don't want a sound at all.
##
## Worth knowing plainly: this covers the seven moments above well, but
## doesn't add new ones. A channeled ability needing a repeating "tick"
## sound, or a multi-hit ability needing a separate impact sound per
## hit, would need Unit.impact_triggered itself to support firing more
## than once per use_ability() call — it currently doesn't. That's a
## change to the combat-level sync signals, a separate and larger
## question from making the existing moments composable.

@export var unit: Unit
@export var default_armed_enter_sfx: SfxCue
@export var default_armed_hold_sfx: AudioStream
@export var default_cast_sfx: SfxCue
@export var default_impact_sfx: SfxCue
## Played instead of nothing at all when this unit takes damage while
## visual_state == POSED (see Unit.visual_state) and the held status
## doesn't set its own StatusEffect.hit_reaction_sfx — left unset (the
## default), a hit taken while posed simply gets no extra cue of its
## own, same as a standing hit already gets none from this script today.
@export var default_hit_reaction_sfx: SfxCue

## The looping "holding a stance" player, parented directly under `unit`
## (not the scene root, unlike VfxEffect's one-shot sequences) —
## deliberately: this loop represents THIS unit's own "armed, waiting to
## act" state, which should end the instant they die, same as any other
## per-unit state. VFX sequences use the scene root instead specifically
## so an in-flight fireball can finish even if its caster died right
## after casting — that reasoning doesn't apply here; there's nothing
## left to finish once the unit holding the stance is gone.
var _hold_player: AudioStreamPlayer3D

## Which ability is currently in flight, and where its target actually
## is, so impact_triggered (a plain, parameterless signal — it's called
## from generic sources, an AnimationPlayer track or an ImpactSignalStep,
## neither of which necessarily has this handy to pass through) knows
## which impact_sfx to play, and WHERE — a ranged/AoE impact happens at
## the target, potentially far from the attacker, not at the attacker's
## own position. Neither is cleared explicitly — a unit can only ever
## have one ability in flight at a time (use_ability() is gated by
## can_act()/busy-state), so the next ability_use_started always
## overwrites both safely before either could be misread as stale.
var _pending_ability: Ability
var _pending_target_position: Vector3


func _ready() -> void:
	if not unit:
		push_warning("unit_sfx.gd needs `unit` assigned in the Inspector.")
		return

	AbilityManager.ability_armed.connect(_on_ability_armed)
	unit.ability_use_started.connect(_on_ability_use_started)
	unit.impact_triggered.connect(_on_impact_triggered)
	unit.took_damage.connect(_on_took_damage)
	unit.status_applied.connect(_on_status_applied)
	unit.status_ticked.connect(_on_status_ticked)
	unit.status_removed.connect(_on_status_removed)


func _on_ability_armed(ability: Ability) -> void:
	if CombatManager.current_unit != unit:
		return

	_stop_hold_loop()

	if not ability:
		return  # disarmed — nothing more to play

	var enter_cue: SfxCue = ability.armed_enter_sfx if ability.armed_enter_sfx else default_armed_enter_sfx
	_play_cue(enter_cue, unit.global_position)

	var hold_sfx: AudioStream = ability.armed_hold_sfx if ability.armed_hold_sfx else default_armed_hold_sfx
	_start_hold_loop(hold_sfx)


## Launching ANY ability ends the "holding a stance" state, regardless
## of whether it was specifically the armed one that fired (e.g.
## clicking an enemy with nothing explicitly armed, falling back to
## default_ability() — see AbilityManager) — either way, the unit isn't
## standing in an armed stance anymore the instant something launches.
func _on_ability_use_started(attacker: Unit, target, ability: Ability) -> void:
	_stop_hold_loop()

	_pending_ability = ability
	_pending_target_position = target.global_position if target is Unit else (target if target is Vector3 else attacker.global_position)

	var cast_cue: SfxCue = ability.cast_sfx if ability.cast_sfx else default_cast_sfx
	_play_cue(cast_cue, attacker.global_position)


## impact_sfx now lives on the optional Ability.timing (see
## AbilityTiming) rather than directly on Ability — most abilities have
## no timing assigned at all, in which case this falls straight through
## to the generic default, same as if impact_sfx had simply been unset.
func _on_impact_triggered() -> void:
	var ability: Ability = _pending_ability
	var impact_cue: SfxCue = default_impact_sfx
	if ability and ability.timing and ability.timing.impact_sfx:
		impact_cue = ability.timing.impact_sfx
	_play_cue(impact_cue, _pending_target_position)


## Reads the currently-held status's own hit_reaction_sfx if it set one
## (see StatusEffect), otherwise this script's own default — same
## pattern as unit_animator.gd's/unit_vfx.gd's _on_took_damage, reading
## the SAME Unit.posed_status rather than tracking pose state
## independently here.
func _on_took_damage(hit_unit: Unit, _amount: int) -> void:
	if not hit_unit.is_alive():
		return

	var posed: StatusEffect = hit_unit.posed_status
	var cue: SfxCue = posed.hit_reaction_sfx if posed and posed.hit_reaction_sfx else default_hit_reaction_sfx
	_play_cue(cue, hit_unit.global_position)


## Status SFX plays at the affected unit's own position, same reasoning
## as unit_vfx.gd's status handlers — see StatusEffect's Apply/Tick/
## Remove FX groups.
func _on_status_applied(affected_unit: Unit, effect: StatusEffect) -> void:
	_play_cue(effect.apply_sfx, affected_unit.global_position)


func _on_status_ticked(affected_unit: Unit, effect: StatusEffect) -> void:
	_play_cue(effect.tick_sfx, affected_unit.global_position)


func _on_status_removed(affected_unit: Unit, effect: StatusEffect) -> void:
	_play_cue(effect.remove_sfx, affected_unit.global_position)


func _play_cue(cue: SfxCue, position: Vector3) -> void:
	if not cue:
		return
	cue.play(get_tree().current_scene, position)


func _start_hold_loop(stream: AudioStream) -> void:
	if not stream:
		return
	_hold_player = AudioStreamPlayer3D.new()
	unit.add_child(_hold_player)
	_hold_player.stream = stream
	_hold_player.play()


func _stop_hold_loop() -> void:
	if _hold_player and is_instance_valid(_hold_player):
		_hold_player.queue_free()
	_hold_player = null
