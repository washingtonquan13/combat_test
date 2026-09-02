class_name ImpactSignalStep
extends VfxStep
## Calls caster.notify_impact() the instant this step is reached in the
## sequence — the piece that actually connects a VFX sequence's timing
## to gameplay. Place it wherever "impact" genuinely happens visually —
## typically right after a ProjectileStep (the moment a projectile
## arrives), before whatever comes next (an explosion's
## SpawnParticleStep). For an ability with waits_for_impact set (see
## Ability), UnitCombat.use_ability() is paused waiting on exactly this
## call — reaching this step is what lets damage actually apply.
##
## Does nothing (silently) if caster wasn't passed through to this
## sequence's play() call — sequences not tied to an ability use (a
## death effect, say) legitimately have no caster to notify, and this
## step simply has no effect in that context rather than erroring.
##
## Resolves instantly — this step never blocks the sequence, it just
## fires the signal and lets the next step start immediately after.


func play(_context: Node, _from: Vector3, _to: Vector3, _ability: Ability = null, caster: Unit = null) -> void:
	if caster:
		caster.notify_impact()


func describe() -> String:
	return "Signal impact"
