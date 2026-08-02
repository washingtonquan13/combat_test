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
## damage dealt; a future MoveCasterEffect might return nothing
## meaningful). target's type depends on what the ability's
## AbilityTargeting validated — usually a Unit, eventually a Vector3.
## Override in each subclass.
func apply(_attacker: Unit, _target) -> Dictionary:
	return {}


## Human-readable summary for tooltips (see hotbar_slot.gd). Override in
## each subclass.
func describe() -> String:
	return ""
