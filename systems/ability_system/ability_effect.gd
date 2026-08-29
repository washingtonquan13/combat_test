class_name AbilityEffect
extends Resource
## Base class for "what happens when this ability resolves." One
## subclass per effect (deal damage, and later: move the caster, apply a
## status, etc.) instead of every possible effect's fields living on one
## shared Ability resource. An ability's effects array can hold more
## than one at once — a leap attack, once built, would plausibly be
## [MoveCasterEffect, DamageEffect] together, applied in order.

## Applies this effect and returns a dict of whatever's relevant for
## logging/UI — shape varies by effect subclass (a DamageEffect returns
## damage dealt; MoveCasterEffect returns distance jumped). target's type
## depends on what the ability's AbilityTargeting validated — a Unit for
## single-target abilities, a Vector3 for point/area ones. ability is the
## Ability this effect belongs to — mainly so an area-based effect can
## read its sibling AreaTargeting's radius (see AreaDamageEffect) instead
## of carrying its own separate radius field that could drift out of
## sync with a sibling effect's copy. Override in each subclass.
func apply(_attacker: Unit, _target, _ability: Ability, _is_critical: bool) -> Dictionary:
	return {}


## Human-readable summary for tooltips (see hotbar_slot.gd). Override in
## each subclass.
func describe() -> String:
	return ""


## Expected damage this effect would deal to ONE target if attacker used
## it right now, without actually rolling or requiring a real target —
## AiScorer's own building block for ranking candidate actions before
## committing to one. Base default 0.0 covers every non-damaging effect
## (a buff, a status application) for free. Override in each damage-
## dealing subclass; see DamageEffect for the plain-dice case and
## StDamageEffect for the attacker-ST-derived one.
func expected_damage(_attacker: Unit) -> float:
	return 0.0


## Expected HP this effect would restore to ONE target — the heal-side
## mirror of expected_damage() above, same reasoning. Override in each
## healing subclass.
func expected_heal(_attacker: Unit) -> float:
	return 0.0
