class_name Ability
extends Resource
## Data for one combat ability, composed from independent pieces rather
## than one flat set of fields covering every possible ability shape —
## see AbilityTargeting and AbilityEffect for why. This resource only
## holds what's genuinely universal to every ability regardless of what
## it does: a name/icon, HOW it picks a target (targeting), WHAT happens
## when it resolves (effects, plural — an ability can combine more than
## one), turn-economy cost, and armed/cast SFX (every ability gets
## armed and used, projectile or not).
##
## Timing (waits_for_impact) and impact SFX are deliberately NOT here —
## see AbilityTiming. Only abilities with a genuinely distinct launch/
## impact shape (a projectile, a synced melee swing) assign one; most
## abilities leave Ability.timing unset entirely rather than carrying
## fields for a concept that was never relevant to them.
##
## Create instances as .tres files (editor: right-click in FileSystem >
## New Resource > Ability), assign a targeting resource and one or more
## effect resources in the Inspector.

@export var ability_name: String = "Basic Attack"
@export var icon: Texture2D

@export var targeting: AbilityTargeting
@export var effects: Array[AbilityEffect] = []

@export_group("Cost")
## Whether landing a hit requires a to-hit roll (Unit.roll_vs) before any
## effects apply, or effects just always happen. Resolved ONCE per
## use_ability() call, not per-effect — see DamageEffect's doc comment
## for why a miss needs to skip every effect together, not just damage.
@export var requires_to_hit: bool = true
## Whether this counts against the once-per-turn attack action
## (Unit.has_attacked). Every current ability does; kept as an explicit
## flag rather than assumed so a future free-action ability doesn't need
## special-casing anywhere else.
@export var uses_attack_action: bool = true

@export_group("Timing")
## Optional — see AbilityTiming's own header for the full reasoning.
## Leave unset for anything without a genuinely distinct launch/impact
## shape (buffs, passives, adjacent-target heals, ...); assign one only
## for abilities where "impact" is a real, separate moment from "use" —
## a projectile, or a melee swing synced to an animation's connect frame.
@export var timing: AbilityTiming

@export_group("Impact FX")
## Optional per-ability composable VFX sequence — see VfxEffect. Left
## unset, unit_vfx.gd falls back to its own generic default sequence, so
## you only need to fill this in for abilities that should look/sound
## distinct (a Fireball's [ProjectileStep, SpawnParticleStep] vs. a
## Sword Attack's plain hit). Replaces an earlier flat PackedScene+
## AudioStream pair — a single composable sequence can express a
## projectile and timing between steps without needing separate fields
## for each visual thing that might play.
##
## For SOUND specifically, prefer cast_sfx below / timing.impact_sfx
## over adding a PlaySoundStep here — see those fields' doc comments for
## why: this sequence's steps have their own internal lifecycle/cleanup
## logic that audio has no reason to depend on, and a purely visual
## change here has already once silently broken audio timing as a
## result. PlaySoundStep still exists and is still the right tool for a
## sound that needs precise positioning relative to a specific mid-
## sequence VFX moment with no corresponding combat signal — just not
## the default choice for the common cases anymore.
@export var impact_vfx: VfxEffect

@export_group("Armed Stance SFX")
## Optional per-ability overrides for the sound played the instant this
## ability becomes armed (a composable SfxCue — see that file), and the
## sound looped for as long as it STAYS armed (a plain AudioStream, not
## a cue — a sustained loop is a genuinely different case from a
## layerable one-shot burst; "layer multiple simultaneous loops" is a
## rare enough need that it isn't worth the same composition here). See
## unit_sfx.gd, which owns these moments. Left unset, unit_sfx.gd falls
## back to its own generic defaults. Universal to every armable ability
## — arming isn't a projectile-specific concept, unlike impact.
@export var armed_enter_sfx: SfxCue
@export var armed_hold_sfx: AudioStream

@export_group("Cast SFX")
## Optional composable sound (see SfxCue) played the instant this
## ability's use is confirmed (Unit.ability_use_started) — genuinely
## universal, unlike impact_sfx (see AbilityTiming): every ability fires
## that signal, projectile or not, so even a pure self-buff can
## meaningfully want a cast sound here. Named cast_sfx rather than
## launch_sfx specifically to avoid smuggling the same projectile-only
## assumption AbilityTiming was split out to remove — this fires for
## literally every ability use.
@export var cast_sfx: SfxCue


## Whether target is a legal target for this ability from attacker's
## current position — delegates entirely to targeting, since range/LoS
## rules are its concern, not this resource's. Returns false if no
## targeting is assigned at all (a misconfigured ability, not a valid
## no-target ability — those don't exist yet, see this file's header).
func is_in_range(attacker: Unit, target) -> bool:
	if not targeting:
		return false
	return targeting.is_valid_target(attacker, target)


## The PathedProjectileStep in impact_vfx.steps, if this ability has one
## — used by seeking_indicator.gd (via PlayerInteractionState) to decide
## whether to preview the real NavigationGrid route instead of
## line_of_sight_indicator.gd's straight aim line, and to read that
## step's OWN radius/avoidance_margin/height/flying/launch_height_offset
## for the preview query, so it can't disagree with what the actual cast
## will do (same WYSIWYG principle AreaIndicator uses reading
## AreaTargeting.radius directly). Derived from the actual VFX
## composition rather than a separate hand-set "is this a seeking
## ability" flag, so it can't drift out of sync with what impact_vfx
## actually plays.
func get_pathed_projectile_step() -> PathedProjectileStep:
	if not impact_vfx:
		return null
	for step in impact_vfx.steps:
		if step is PathedProjectileStep:
			return step
	return null


func has_pathed_projectile() -> bool:
	return get_pathed_projectile_step() != null


## The MoveCasterEffect in effects, if this ability has one — used by
## AbilityManager (an armed movement-budget ability like Jump shouldn't
## auto-disarm just because the attack action is spent, only once move
## budget itself runs out) and jump_indicator.gd (to preview the exact
## arc that effect will produce). Same shape as get_pathed_projectile_step
## above: derived from the actual effect composition rather than a
## separate hand-set flag, so both call sites can't independently drift
## out of sync with each other or with what the ability actually does.
func get_move_caster_effect() -> MoveCasterEffect:
	for effect in effects:
		if effect is MoveCasterEffect:
			return effect
	return null


func has_move_caster_effect() -> bool:
	return get_move_caster_effect() != null
