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
