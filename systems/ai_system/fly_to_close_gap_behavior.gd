class_name FlyToCloseGapBehavior
extends AiBehavior
## Takes off specifically when the GROUNDED route to the nearest hostile
## is meaningfully more expensive than the FLYING one would be — a real
## obstacle course, a chasm, a tall wall — rather than on reflex like
## PreferFlightBehavior's own takeoff candidate (which fires
## unconditionally whenever grounded). This is what a unit authored with
## ONLY this behavior, and not MaintainAltitude, uses flight for: purely
## as a shortcut past terrain, never as a standing preference.
##
## Compares both routes at the SAME cost scale — the ground one is the
## unit's own UnitMovement.plan_route (ladders included), the flying one
## RoutePlanner.plan() over a flying NavigationGrid.find_path() — with
## the flying leg's own ascend/descend multipliers applied (see
## FlightRules), so "meaningfully cheaper" already accounts for climbing
## being expensive, not just raw distance.
## Only ever proposes the takeoff itself; the resulting attack (or
## further repositioning) is left to whatever runs after this unit is
## actually airborne (MaintainAltitude/Swoop, or the plain baseline
## enumeration if neither is authored).

## Ground cost must exceed flying cost by at least this multiple before
## taking off is worth it — 1.0 would take off for even a 1% advantage;
## higher demands a real, meaningful detour before spending FP on it.
@export var cost_advantage_threshold: float = 1.25
@export var score_bonus: float = 0.0


func _propose_candidates(unit: Unit) -> Array[AiPlan]:
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
	var ground_cost: float = _ground_cost(unit, goal)
	var flight_cost: float = _flight_cost(unit, Vector3(goal.x, _flight_altitude_for(target), goal.z))

	if flight_cost == INF or ground_cost < flight_cost * cost_advantage_threshold:
		return []

	var plan: AiPlan = self_plan(unit, flight_ability, score_bonus)
	plan.reason = "fly: shortcut past terrain"
	return [plan]


func _flight_altitude_for(target: Unit) -> float:
	return UnitMovement.clamp_flight_altitude(target.global_position.y, target.global_position, target)


## The grounded unit's own route query (UnitMovement.plan_route, through
## the scorer's per-pass cache), so a ladder that gets it there counts —
## the same route it walks if it doesn't take off. INF if there is no
## route at all.
func _ground_cost(unit: Unit, goal: Vector3) -> float:
	var planned: Dictionary = AiScorer.route(unit, goal)
	if planned.path.size() < 2:
		return INF
	return planned.cumulative_cost[planned.cumulative_cost.size() - 1]


## The route the unit would fly once airborne — find_path in flying mode
## with the flier's vertical multipliers. INF if there is none at all: an
## unreachable route can never look "cheaper" than one that exists.
func _flight_cost(unit: Unit, goal: Vector3) -> float:
	var waypoints: PackedVector3Array = NavigationGrid.find_path(unit.get_tree(), unit.global_position, goal, unit, true)
	if waypoints.size() < 2:
		return INF
	var rules: FlightRules = UnitMovement.FLIGHT_RULES
	var planned: Dictionary = RoutePlanner.plan(waypoints, INF, SurfaceManager.cost_sampler(unit), rules.ascend_cost_multiplier, rules.descend_cost_multiplier)
	if planned.cumulative_cost.size() == 0:
		return INF
	return planned.cumulative_cost[planned.cumulative_cost.size() - 1]
