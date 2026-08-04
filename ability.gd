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

@export_group("Impact FX")
## Optional per-ability composable VFX sequence — see VfxEffect. Left
## unset, unit_vfx.gd falls back to its own generic default sequence, so
## you only need to fill this in for abilities that should look/sound
## distinct (a Fireball's [ProjectileStep, SpawnParticleStep,
## PlaySoundStep] vs. a Sword Attack's generic clang). Replaces an
## earlier flat PackedScene+AudioStream pair — a single composable
## sequence can express both (and a projectile, and timing between
## them) without needing separate fields for each kind of thing that
## might play.
@export var impact_vfx: VfxEffect


## Whether target is a legal target for this ability from attacker's
## current position — delegates entirely to targeting, since range/LoS
## rules are its concern, not this resource's. Returns false if no
## targeting is assigned at all (a misconfigured ability, not a valid
## no-target ability — those don't exist yet, see this file's header).
func is_in_range(attacker: Unit, target) -> bool:
	if not targeting:
		return false
	return targeting.is_valid_target(attacker, target)
