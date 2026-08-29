class_name SwoopAttackBehavior
extends AiBehavior
## Dives to melee range and strikes, then (implicitly — see this file's
## own header on why nothing here ever lands) climbs back to whatever a
## sibling MaintainAltitudeBehavior prefers once combat_ai's normal
## reach/standoff machinery re-plans next turn. Only proposes anything
## while already airborne — MaintainAltitudeBehavior (or
## FlyToCloseGapBehavior) owns getting off the ground in the first
## place; this behavior's only job is the dive.
##
## Sets AiPlan.flight_altitude to swoop_altitude WITHOUT setting a
## destination itself — AiScorer._resolve_reach temporarily adopts that
## altitude before planning the route (see that method's own header), so
## the standoff point it computes already accounts for the dive, and the
## resulting plan reads as one continuous "descend into range" move
## rather than two separate actions. If the unit is already within
## melee range at its CURRENT altitude, this still fires — is_in_range()
## is checked at the real current position first, same as every other
## candidate — so a swooper already low enough just attacks immediately
## without an extra unnecessary dive.

@export var swoop_altitude: float = 1.0
## Which ability actually lands the hit — a melee attack, almost always.
## Falls back to unit.default_ability() when unset, same convention
## UseAbilityOnNearestHostileBehavior's own `ability` field uses.
@export var swoop_ability: Ability
@export var score_bonus: float = 0.0


func propose(unit: Unit) -> Array[AiPlan]:
	if not unit.is_flying():
		return []

	var target: Unit = UnitQuery.nearest_hostile(unit.get_tree(), unit)
	if not target:
		return []
	var ability: Ability = swoop_ability if swoop_ability else unit.default_ability()
	if not ability:
		return []

	var plan := AiPlan.new(ability, target)
	plan.flight_altitude = swoop_altitude
	plan.score = score_bonus
	return [plan]
