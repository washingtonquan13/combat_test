class_name DismissTargeting
extends AbilityTargeting
## Targets one of the attacker's own currently-fielded demons. The
## ownership check (summoned_by == attacker) lives here, in targeting,
## matching how every other targeting subclass already answers "is this
## an appropriate thing to target," not just geometry (see
## AbilityTargeting's own header).
##
## Also requires owned_demon != null — summoned_by alone would also
## match a plain, non-demon SummonEffect summon (e.g. the Tiefling
## Wizard's existing Summon Spirit), which DismissEffect can't handle:
## it writes back into target.owned_demon, which would be null on a
## non-demon summon.
##
## No range/LoS check at all, unlike most targeting subclasses —
## recalling a demon through its contract doesn't need physical
## proximity, and the plan this was built from never specified a range
## for it.

func is_valid_target(attacker: Unit, target) -> bool:
	return target is Unit and target.summoned_by == attacker and target.owned_demon != null and target.is_alive()


func has_any_valid_target(attacker: Unit) -> bool:
	for unit in UnitQuery.all_units(attacker.get_tree()):
		if is_valid_target(attacker, unit):
			return true
	return false


func describe() -> String:
	return "Dismisses one of your fielded demons"
