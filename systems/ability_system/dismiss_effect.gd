class_name DismissEffect
extends AbilityEffect
## Withdraws one of the attacker's fielded demons — a deliberate,
## voluntary departure, distinct from a real combat death (see
## UnitCombat.take_damage(), which permanently releases the roster entry
## instead). Syncs the live Unit's current HP/FP back onto its
## OwnedDemon roster entry FIRST, so however damaged it currently is
## survives the withdrawal — re-summoning it later (SummonDemonEffect)
## reads these same values back out, rather than resetting to full
## health for free just by dismissing and re-summoning.
##
## Reuses UnitDeath.expire() for the actual departure, same as a timed
## summon's own expiry (DespawnOnExpireBehavior) — including that path's
## "fades away" log line and death VFX. A distinct "departed peacefully"
## presentation is real follow-up work, not built here — an accepted,
## precedented limitation, not an oversight.

func apply(_attacker: Unit, target, _ability: Ability, _is_critical: bool) -> Dictionary:
	if not target is Unit or not target.owned_demon:
		return {}

	var unit_target: Unit = target
	unit_target.owned_demon.current_hp = unit_target.current_hp
	unit_target.owned_demon.current_fp = unit_target.current_fp
	unit_target.expire()
	return {"dismissed": unit_target}


func describe() -> String:
	return "Withdraws a fielded demon, preserving its current HP/FP"
