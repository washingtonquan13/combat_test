class_name AiBehavior
extends Resource
## One composable AI decision rule. AiScorer.best_plan() pools every
## candidate a unit's own ai_behaviors propose alongside its baseline
## attack-ability enumeration (see that file's own header) and picks
## whichever scores highest overall — behaviors CONTRIBUTE candidates,
## they don't short-circuit the decision the way this class's old
## resolve()-returns-first-match contract did.
##
## THE CONTRACT, in one line: a behavior proposes candidates and an
## authored bias. It never prices, never decides, and never repositions
## when it could already act.
##
## Each clause of that is there because breaking it shipped a bug:
##
##   never PRICES — a takeoff was authored at a flat 1.0 and lost forever
##     to a 1.35 damage figure, because nothing converted between the two.
##     Two flight behaviors then hand-rolled their own threat arithmetic
##     and competed against each other on an unstated scale. All value
##     lives in AiScorer now (see _score_plan and _apply_positional_value,
##     both in one HP currency); a behavior's `bias` only breaks ties
##     between candidates the scorer already considers comparable.
##
##   never DECIDES — a landing branch `return`ed a single plan the moment
##     its precondition held, so an Avian hovering two metres above a
##     brute landed straight into its reach. Propose the landing AND the
##     alternatives; let scoring answer. _propose_candidates returning an
##     array, and propose() validating it, is what makes "return the whole
##     set" the path of least resistance.
##
##   never REPOSITIONS when it could act — see AiPlan.movement_intent for
##     the flyer that spent every turn drifting toward an altitude it
##     could not afford to reach while the party stood in range below it.
##     Use the builders below and you get the safe intent by default.
##
## Range/approach is still handled entirely by AiScorer/CombatAI's
## existing standoff/reach machinery — a behavior should never check
## range itself.

## Returns every candidate this behavior thinks unit could reasonably
## take right now — empty if none apply. OVERRIDE THIS, not propose().
func _propose_candidates(_unit: Unit) -> Array[AiPlan]:
	return []


## Final. Wraps _propose_candidates with the contract checks above, so a
## violation surfaces at the behavior that caused it rather than three
## systems away as a unit behaving strangely. Debug-only: release builds
## pay nothing, since by then the authored content is fixed.
func propose(unit: Unit) -> Array[AiPlan]:
	var plans: Array[AiPlan] = _propose_candidates(unit)
	if OS.is_debug_build():
		for plan in plans:
			_assert_valid(unit, plan)
	return plans


func _assert_valid(unit: Unit, plan: AiPlan) -> void:
	var who: String = get_script().get_global_name()
	assert(plan != null, "%s proposed a null plan" % who)
	assert(plan.target != null,
		"%s proposed a plan with no target — AiScorer._prepare_plan discards it silently" % who)
	assert(plan.pure_reposition or plan.ability != null,
		"%s proposed a non-reposition plan with no ability" % who)
	# The scorer owns value; a behavior setting a large score is trying to
	# price its own plan, which is the bug this contract exists to stop.
	assert(absf(plan.score) <= MAX_AUTHORED_BIAS,
		"%s set score %.2f — behaviors set a small authored BIAS, not a value (see this file's header)"
			% [who, plan.score])
	# An IF_NEEDED move that's already in range is dead weight; the scorer
	# strips it, but flagging it here points at the behavior that meant to
	# say REQUIRED.
	if (plan.has_destination and plan.movement_intent == AiPlan.MovementIntent.IF_NEEDED
			and not plan.pure_reposition and plan.ability and plan.target is Unit):
		assert(not plan.ability.is_in_range(unit, plan.target),
			"%s set an IF_NEEDED destination while already in range — say REQUIRED if the move IS the point" % who)


## Ceiling on what a behavior may set as its own bias. Sized against
## AiScorer's HP currency: a few points of expected damage, enough to
## break a tie or express an authored preference, never enough to
## override a genuinely urgent action. Anything bigger means the behavior
## is trying to compute value, which is AiScorer's job.
const MAX_AUTHORED_BIAS: float = 10.0


# --- Plan builders -------------------------------------------------
# Subclasses build plans through these rather than AiPlan.new(), so the
# right movement_intent is picked per plan KIND instead of being
# remembered (or forgotten) per behavior.

## Attack (or otherwise use an ability on) target. Moves only if the
## ability isn't already usable from where unit stands — see
## AiPlan.movement_intent. Pass `destination` to insist on a particular
## spot to act from; leave it null to let AiScorer.standoff_goal decide.
func attack_plan(_unit: Unit, target: Unit, ability: Ability, bias: float = 0.0,
		destination = null, flight_altitude: float = NAN) -> AiPlan:
	var plan := AiPlan.new(ability, target)
	plan.score = bias
	if destination != null:
		plan.with_destination(destination, flight_altitude)
		plan.movement_intent = AiPlan.MovementIntent.IF_NEEDED
	return plan


## Go somewhere, full stop — the movement IS the action (fleeing,
## withdrawing). Marked pure_reposition, so AiScorer skips the
## ability-economy checks and damage scoring entirely: `ability` on such a
## plan is a formality (see AiPlan.pure_reposition).
func reposition_plan(unit: Unit, target: Unit, destination: Vector3, bias: float = 0.0,
		flight_altitude: float = NAN) -> AiPlan:
	var plan := AiPlan.new(unit.default_ability(), target)
	plan.mark_pure_reposition()
	plan.with_destination(destination, flight_altitude)
	plan.movement_intent = AiPlan.MovementIntent.REQUIRED
	plan.score = bias
	return plan


## Use a self-targeted ability — takeoff, landing, a self-buff. Never
## carries a destination.
func self_plan(unit: Unit, ability: Ability, bias: float = 0.0) -> AiPlan:
	var plan := AiPlan.new(ability, unit)
	plan.score = bias
	return plan


## Use a ground/area-targeted ability at a point. AiPlan.target is a
## Vector3 for these, not a Unit — the "type depends on targeting"
## convention Ability.is_in_range and AbilityEffect.apply already use.
func point_plan(_unit: Unit, ability: Ability, point: Vector3, bias: float = 0.0) -> AiPlan:
	var plan := AiPlan.new(ability, point)
	plan.score = bias
	return plan


## Move to a specific spot AND act from it, where the spot genuinely
## matters — a dive to melee range, a climb to a firing altitude. Unlike
## attack_plan this keeps its destination even when the ability is
## already in range, because arriving is part of the intent.
func positioned_attack_plan(_unit: Unit, target: Unit, ability: Ability, destination: Vector3,
		bias: float = 0.0, flight_altitude: float = NAN) -> AiPlan:
	var plan := AiPlan.new(ability, target)
	plan.with_destination(destination, flight_altitude)
	plan.movement_intent = AiPlan.MovementIntent.REQUIRED
	plan.score = bias
	return plan
