class_name FlightAiUtil
extends RefCounted
## Small shared lookups the flight AI behaviors (MaintainAltitude, Swoop,
## FlyToCloseGap, Flee) all need — factored out here rather than
## duplicated per-behavior, same reasoning UnitQuery collects its own
## shared scans for. Type-checked against the actual effect present on
## an ability (GrantFlightEffect/LandEffect), not compared against a
## specific fly.tres/land.tres resource, so this works for any unit
## carrying any flight-granting/landing ability, not just the two
## authored ones today — mirrors the old CombatAI._find_flight_ability
## this replaces (see combat_ai.gd's own header on why that hardcoded
## hack was removed from there).

static func find_flight_ability(unit: Unit) -> Ability:
	for ability in unit.abilities:
		for effect in ability.effects:
			if effect is GrantFlightEffect:
				return ability
	return null


static func find_land_ability(unit: Unit) -> Ability:
	for ability in unit.abilities:
		for effect in ability.effects:
			if effect is LandEffect:
				return ability
	return null


## FP per turn this unit's active flight actually costs — 0 if it isn't
## flying, or if whatever grants its flight has no upkeep. Read off the
## granting statuses rather than assumed, since a species could carry a
## cheaper or pricier flight status later and a hardcoded 1 would quietly
## mistime every descent that depends on this.
static func flight_upkeep(unit: Unit) -> int:
	var total: int = 0
	for status in unit.flight_granting_statuses():
		total += status_upkeep(status)
	return total


## Upkeep of a flight status this unit has NOT applied yet — what taking
## off would commit it to. flight_upkeep() above can only see statuses
## already active, which is exactly no help to a grounded unit deciding
## whether it can afford to leave the ground in the first place.
static func prospective_flight_upkeep(ability: Ability) -> int:
	if not ability:
		return 0
	for effect in ability.effects:
		if effect is GrantFlightEffect and effect.flying_status:
			return status_upkeep(effect.flying_status)
	return 0


static func status_upkeep(status: StatusEffect) -> int:
	var total: int = 0
	for behavior in status.behaviors:
		if behavior is FpDrainBehavior:
			total += behavior.fp_per_turn
	return total
