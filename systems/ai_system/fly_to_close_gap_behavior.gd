class_name FlyToCloseGapBehavior
extends AiBehavior
## Takes off specifically when the GROUNDED route to the nearest hostile
## is meaningfully more expensive than the FLYING one would be — a real
## obstacle course, a chasm, a tall wall — rather than on reflex like
## MaintainAltitudeBehavior's own takeoff candidate (which fires
## unconditionally whenever grounded). This is what a unit authored with
## ONLY this behavior, and not MaintainAltitude, uses flight for: purely
## as a shortcut past terrain, never as a standing preference.
##
## Compares both routes at the SAME cost scale — RoutePlanner.plan() over
## NavigationGrid.find_path(), the exact functions every real move in
## this project already goes through (see UnitMovement.plan_route/
## movement_indicator.gd) — with the flying leg's own ascend/descend
## multipliers applied (see FlightRules), so "meaningfully cheaper"
## already accounts for climbing being expensive, not just raw distance.
## Only ever proposes the takeoff itself; the resulting attack (or
## further repositioning) is left to whatever runs after this unit is
## actually airborne (MaintainAltitude/Swoop, or the plain baseline
## enumeration if neither is authored).

## Ground cost must exceed flying cost by at least this multiple before
## taking off is worth it — 1.0 would take off for even a 1% advantage;
## higher demands a real, meaningful detour before spending FP on it.
@export var cost_advantage_threshold: float = 1.25
@export var score_bonus: float = 0.0


func propose(unit: Unit) -> Array[AiPlan]:
	if unit.is_flying():
		return []

	var flight_ability: Ability = FlightAiUtil.find_flight_ability(unit)
	if not flight_ability:
		return []

	var target: Unit = UnitQuery.nearest_hostile(unit.get_tree(), unit)
	if not target:
		return []
	var ability: Ability = unit.default_ability()
	if not ability:
		return []

	var goal: Vector3 = AiScorer.standoff_goal(unit, target, ability)
	var ground_cost: float = _route_cost(unit, goal, false)
	var flight_cost: float = _route_cost(unit, Vector3(goal.x, _flight_altitude_for(target), goal.z), true)

	if flight_cost == INF or ground_cost < flight_cost * cost_advantage_threshold:
		return []

	var plan := AiPlan.new(flight_ability, unit)
	plan.score = score_bonus
	return [plan]


func _flight_altitude_for(target: Unit) -> float:
	return clamp(target.global_position.y, NavigationGrid.FLIGHT_MIN_ALTITUDE, NavigationGrid.FLIGHT_CEILING_HEIGHT)


## INF if no route exists at all (ground OR flying) — an unreachable
## route can never look "cheaper" than one that at least exists.
func _route_cost(unit: Unit, goal: Vector3, flying: bool) -> float:
	var waypoints: PackedVector3Array = NavigationGrid.find_path(unit.get_tree(), unit.global_position, goal, unit, flying)
	if waypoints.size() < 2:
		return INF
	var ascend: float = UnitMovement.FLIGHT_RULES.ascend_cost_multiplier if flying else 1.0
	var descend: float = UnitMovement.FLIGHT_RULES.descend_cost_multiplier if flying else 1.0
	var planned: Dictionary = RoutePlanner.plan(waypoints, INF, SurfaceManager.movement_cost_multiplier_at, ascend, descend)
	if planned.cumulative_cost.size() == 0:
		return INF
	return planned.cumulative_cost[planned.cumulative_cost.size() - 1]
