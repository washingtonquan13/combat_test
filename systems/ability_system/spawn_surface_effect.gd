class_name SpawnSurfaceEffect
extends AbilityEffect
## Creates a persistent Surface on the battlefield at a ground point —
## target here is a Vector3 (an AoE center), the same shape as
## AreaDamageEffect/AreaApplyStatusEffect, pairing with AreaTargeting the
## same way. Unlike those two, this doesn't affect any unit itself at the
## moment of casting — it just hands off to SurfaceManager, which is what
## actually checks unit overlap, on an ongoing basis, every round from
## here on (see that file). Combine with AreaDamageEffect in the same
## ability's effects array for something like "the initial fireball
## blast, AND it leaves a patch of fire behind" — the instant blast and
## the lingering surface are deliberately two separate effects rather
## than one effect trying to do both.
##
## radius is NOT set here — same single-source-of-truth reasoning as
## AreaDamageEffect: read from ability.targeting.radius (AreaTargeting) so
## the surface's actual footprint can never drift from what the targeting
## indicator showed the player before they committed to the cast.

@export var surface: Surface


func apply(_attacker: Unit, target, ability: Ability) -> Dictionary:
	if not target is Vector3 or not surface:
		return {}

	var targeting := ability.targeting as AreaTargeting
	if not targeting:
		return {}

	SurfaceManager.spawn(surface, target, targeting.radius)
	return {"spawned_surface": surface.surface_name}


func describe() -> String:
	return "Creates a %s surface" % (surface.surface_name if surface else "(no surface set)")
