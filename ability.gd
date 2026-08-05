class_name Ability
extends Resource
## Data for one combat ability, composed from independent pieces rather
## than one flat set of fields covering every possible ability shape —
## see AbilityTargeting and AbilityEffect for why. This resource only
## holds what's genuinely universal to every ability regardless of what
## it does: a name/icon, HOW it picks a target (targeting), WHAT happens
## when it resolves (effects, plural — an ability can combine more than
## one), and turn-economy cost.
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
## If true, use_ability() waits for Unit.notify_impact() — called by an
## attack animation's Call Method Track (placed at the frame a weapon
## actually connects), or a VFX sequence's ImpactSignalStep (typically
## right after a projectile arrives) — before actually applying this
## ability's effects. Damage genuinely lands when the animation/VFX
## SHOWS it landing, not the instant the ability is used. Defaults false
## so abilities without a properly synced animation/VFX set up yet keep
## resolving immediately, exactly as they already do — this is
## deliberately opt-in per ability, not a forced change to everything.
@export var waits_for_impact: bool = false
## Safety timeout — if notify_impact() never arrives (the animation/VFX
## isn't actually wired up to call it, despite waits_for_impact being
## on), effects apply anyway after this many seconds rather than the
## ability hanging forever and stalling the whole turn. A late-but-
## correct resolution is a far safer failure mode than a stuck game.
@export var impact_timeout: float = 3.0

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
## For SOUND specifically, prefer launch_sfx/impact_sfx below (Action
## SFX group) over adding a PlaySoundStep here — see that group's doc
## comment for why: this sequence's steps have their own internal
## lifecycle/cleanup logic that audio has no reason to depend on, and a
## purely visual change here has already once silently broken audio
## timing as a result. PlaySoundStep still exists and is still the right
## tool for a sound that needs precise positioning relative to a
## specific mid-sequence VFX moment with no corresponding combat signal
## — just not the default choice for the two common cases anymore.
@export var impact_vfx: VfxEffect

@export_group("Armed Stance SFX")
## Optional per-ability overrides for the sound played the instant this
## ability becomes armed, and the sound looped for as long as it STAYS
## armed (waiting for the player to pick a target) — see unit_sfx.gd,
## which owns these two specific moments and nothing else (launch/impact
## stay in impact_vfx above). Left unset, unit_sfx.gd falls back to its
## own generic defaults.
@export var armed_enter_sfx: AudioStream
@export var armed_hold_sfx: AudioStream

@export_group("Action SFX")
## Optional per-ability overrides for the sound played at LAUNCH
## (Unit.ability_use_started — the instant use is confirmed, before
## to-hit) and IMPACT (Unit.impact_triggered). These are the two most
## common SFX moments, given their own direct hooks in unit_sfx.gd
## rather than requiring a PlaySoundStep inside impact_vfx for the
## common case — deliberately kept OUT of the VFX sequence, reacting to
## the same unit-level signals animation/VFX already react to, so a
## purely visual change to impact_vfx can never again silently affect
## audio timing (they no longer share any execution path). PlaySoundStep
## remains available inside impact_vfx for sounds that genuinely need to
## be positioned relative to a specific mid-sequence VFX moment (timed
## to a projectile's midpoint, say) that has no corresponding combat
## signal of its own — use whichever fits a given sound's actual need.
@export var launch_sfx: AudioStream
@export var impact_sfx: AudioStream


## Whether target is a legal target for this ability from attacker's
## current position — delegates entirely to targeting, since range/LoS
## rules are its concern, not this resource's. Returns false if no
## targeting is assigned at all (a misconfigured ability, not a valid
## no-target ability — those don't exist yet, see this file's header).
func is_in_range(attacker: Unit, target) -> bool:
	if not targeting:
		return false
	return targeting.is_valid_target(attacker, target)
