class_name AiScorer
extends RefCounted
## Replaces CombatAI's old hardcoded "nearest hostile + default_ability"
## baseline with a scored decision: enumerate every (ability, target)
## candidate this unit could take right now — its own attack abilities
## against every hostile, plus whatever its authored ai_behaviors
## propose (see AiBehavior.propose) — filter out anything it can't
## actually do this turn, and return the single best-scoring AiPlan.
## Stateless static funcs, same convention as UnitQuery/RoutePlanner/
## SuccessRoll: this is pure computation over whatever unit/tree it's
## handed, not an owned component.
##
## Smartness (Unit.ai_smartness) gates WHICH FACTORS are considered, not
## how much noise is added to a good answer — a "dumb" unit picks the
## best action among a NARROWER set of considerations, it never picks a
## worse action on purpose. This is deliberate: randomly degrading a good
## decision reads as broken AI, while a unit that simply doesn't notice
## an opportunity (finishing a kill, conserving FP) reads as naive,
## which is a much more forgiving kind of "not perfect."
##
##   0 Feral    — nearest hostile, default_ability() only. The literal
##                old baseline, byte-for-byte, so existing content is
##                completely unaffected by this rewrite unless a species
##                is deliberately authored above this tier.
##   1 Basic    — considers every attack ability's own expected damage,
##                so it picks the ABILITY that hits hardest rather than
##                always abilities[0].
##   2 Tactical (default) — clamps overkill, rewards a lethal hit, and
##                weights toward finishing a nearly-dead target.
##   3 Cunning  — also conserves FP (won't spend its last cast if that
##                leaves it unable to sustain something already running,
##                e.g. Flying's own upkeep — see FpDrainBehavior).
##
## This scorer reasons about damage DEALT (_score_plan) and damage TAKEN
## (incoming_threat) as two separate halves — a plan's own score_bonus
## plus expected-damage/heal covers the first; authored positioning
## behaviors that care about the second (MaintainAltitudeBehavior's
## takeoff, a future FleeBehavior rewrite) call incoming_threat()
## themselves rather than this file injecting threat-avoidance into
## every candidate's score. Earlier iterations assumed altitude
## reasoning "fell out for free" because AltitudeAdvantageBehavior
## shifts the to-hit number — it does, but that shift caps at +4 and is
## second-order next to simply being out of a melee attacker's reach,
## which is what actually justifies a flyer's takeoff cost.
##
## Known simplifications, not bugs: line of sight is ignored when
## checking whether a standoff point would land a ranged ability in
## range (an approximation of RangedEnemyTargeting's real LoS raycast —
## good enough to rank candidates, not to guarantee the final shot
## connects); ground/area-targeted abilities (Jump, Fireball, ...) are
## entirely out of scope, same documented limitation
## GroundPointTargeting's own header already states for the AI this
## replaces ("an AI unit... would never find a valid target"); "prefers
## targets that are dangerous" from the original design discussion is
## narrowed here to "prefers finishing a nearly-dead target," since this
## project has no existing unit-threat metric to build the fuller
## version on.

const KILL_BONUS: float = 25.0
## How much extra value a hit worth landing on a nearly-dead target
## gains, scaled by how much of its HP is already gone (0 at full HP, up
## to this at 0 HP) — see _score_plan. Not "prefer weak targets
## generally": this only applies AFTER a real damage/kill value is
## already computed, so it breaks ties toward finishing blows rather
## than chasing the technically-lowest-HP unit regardless of whether
## this attack would do anything to them.
const FINISH_WEIGHT: float = 0.5
## Tier 3 (Cunning) only — see that tier's own header line above.
const FP_RESERVE: int = 1
const FP_CONSERVE_PENALTY: float = 3.0

## _success_probability(target_number) memoized across calls within a
## single turn's worth of scoring (many candidates share the same
## attacker skill and often the same target) — 216 outcomes enumerated
## is cheap regardless, but the cache costs nothing either.
static var _success_cache: Dictionary = {}


## The single best AiPlan for unit to act on right now, or null if it has
## no living hostile at all (nothing to do — matches the old baseline's
## own "no target, decline" behavior). Never returns a plan for an
## ability this unit can't actually attempt (see _prepare_plan) except
## the pure-movement fallback (see _fallback_plan's own header), which
## intentionally has has_destination set so CombatAI never tries to fire
## it as an attack.
static func best_plan(unit: Unit) -> AiPlan:
	if unit.ai_smartness <= 0:
		return _feral_plan(unit)

	var tree: SceneTree = unit.get_tree()
	var candidates: Array[AiPlan] = _enumerate_baseline_candidates(unit, tree)
	for behavior in unit.ai_behaviors:
		candidates.append_array(behavior.propose(unit))

	var feasible: Array[AiPlan] = []
	for plan in candidates:
		if _prepare_plan(unit, plan):
			feasible.append(plan)

	if feasible.is_empty():
		return _fallback_plan(unit, tree)

	var best: AiPlan = feasible[0]
	for plan in feasible:
		if plan.score > best.score:
			best = plan
	return best


## Tier 0 — the exact pre-scorer baseline (UnitQuery.nearest_hostile +
## default_ability()), with none of this file's own reasoning applied at
## all. Kept as a fully separate code path rather than "tier 0 of the
## scored pipeline" specifically so it can never silently drift from the
## literal old behavior as the scored path evolves.
static func _feral_plan(unit: Unit) -> AiPlan:
	var target: Unit = UnitQuery.nearest_hostile(unit.get_tree(), unit)
	if not target:
		return null
	var ability: Ability = unit.default_ability()
	if not ability:
		return null
	return AiPlan.new(ability, target)


## Every (attack ability, hostile target) pair worth considering as a
## candidate — the generalized replacement for "abilities[0] against
## nearest hostile." Restricted to MeleeEnemyTargeting/RangedEnemyTargeting
## abilities that actually deal damage (see AbilityEffect.expected_damage):
## a buff/heal/utility ability (Bless, Fly, Land, ...) was never part of
## the old "attack nearest hostile" baseline either, and giving one to a
## unit that should use it is an authored AiBehavior's job (see
## HealWoundedAllyBehavior), not something this blanket enumeration
## should guess at.
static func _enumerate_baseline_candidates(unit: Unit, tree: SceneTree) -> Array[AiPlan]:
	var candidates: Array[AiPlan] = []

	var hostiles: Array[Unit] = []
	for other in UnitQuery.living_units(tree):
		if unit.is_hostile_to(other):
			hostiles.append(other)
	if hostiles.is_empty():
		return candidates

	for ability in unit.abilities:
		if not ability.targeting:
			continue
		if not (ability.targeting is MeleeEnemyTargeting or ability.targeting is RangedEnemyTargeting):
			continue

		var total_damage: float = 0.0
		for effect in ability.effects:
			total_damage += effect.expected_damage(unit)
		if total_damage <= 0.0:
			continue

		for target in hostiles:
			candidates.append(AiPlan.new(ability, target))

	return candidates


## Hard preconditions, same rules UnitCombat.use_ability() itself
## enforces (attack action, move_cost, fp_cost, ally-target structural
## mismatch — see that file's own doc comments for why each one exists),
## checked here BEFORE spending a turn attempting something that would
## just be refused. Returns false to discard the candidate outright, true
## once the plan is safe to score and possibly execute — resolving reach
## (see _resolve_reach) and scoring (see _score_plan) both happen here so
## a caller only has one "is this usable, and how good" answer to work
## with, not a pipeline of separate calls it needs to run in order.
static func _prepare_plan(unit: Unit, plan: AiPlan) -> bool:
	if not plan or plan.target == null:
		return false
	if not plan.pure_reposition and not plan.ability:
		return false

	if not plan.pure_reposition:
		var ability: Ability = plan.ability
		if ability.attack_action_spent_by(unit):
			return false
		if CombatManager.in_combat and ability.move_cost > 0.0 and unit.move_remaining < ability.move_cost:
			return false
		if ability.fp_cost > 0.0 and unit.current_fp < ability.fp_cost:
			return false
		if ability.targeting and ability.targeting.requires_ally_target() and plan.target is Unit and unit.is_hostile_to(plan.target):
			return false

	if not _resolve_reach(unit, plan):
		return false

	if not plan.pure_reposition:
		_score_plan(unit, plan)

	return true


## Whether unit can actually get into range to act on plan this turn —
## and if not already in range, where it would need to stand. A plan
## that already carries its own destination (an authored positioning
## behavior — see systems/ai_system's flight behaviors) is trusted for
## WHERE to go; this only confirms SOME progress toward it is possible,
## since a repositioning move isn't trying to land in a specific
## ability's range at all. Everything else uses AiScorer.standoff_goal —
## the exact same point CombatAI itself moves toward once this plan is
## chosen, so a candidate that scores as "reachable" here can't disagree
## with what actually happens next.
static func _resolve_reach(unit: Unit, plan: AiPlan) -> bool:
	# A plan may name a flight_altitude the unit hasn't actually adopted
	# yet (see SwoopAttackBehavior — "dive to melee range" only makes
	# sense planned against the DIVE altitude, not wherever the unit
	# currently happens to be) — temporarily adopt it for this route
	# query alone, then restore, so scoring one candidate can never leak
	# a fake altitude into any other candidate scored in the same pass.
	# Direct field write, not set_flight_altitude()'s clamped setter: the
	# value being restored was already valid (it's whatever the unit
	# already had), so re-clamping it here would be redundant.
	var previous_altitude: float = unit.flight_target_altitude
	if not is_nan(plan.flight_altitude):
		unit.set_flight_altitude(plan.flight_altitude)

	var reachable: bool = _resolve_reach_at_current_altitude(unit, plan)

	if not is_nan(plan.flight_altitude):
		unit.flight_target_altitude = previous_altitude

	return reachable


static func _resolve_reach_at_current_altitude(unit: Unit, plan: AiPlan) -> bool:
	var budget: float = unit.move_remaining if CombatManager.in_combat else INF

	if plan.has_destination:
		if unit.global_position.distance_to(plan.destination) <= unit.arrival_tolerance:
			return true
		var moving_plan: Dictionary = unit.plan_route(plan.destination, budget)
		return moving_plan.path.size() >= 2

	if not plan.ability:
		return false

	if plan.ability.is_in_range(unit, plan.target):
		return true

	if not plan.target is Unit:
		# Ground/area-targeted abilities are out of scope — see this
		# file's own header.
		return false

	var goal: Vector3 = AiScorer.standoff_goal(unit, plan.target, plan.ability)
	var planned: Dictionary = unit.plan_route(goal, budget)
	if planned.path.size() < 2:
		return false

	var arrival: Vector3 = planned.path[planned.path.size() - 1]
	if not _would_be_in_range(arrival, unit, plan.target, plan.ability):
		return false

	plan.destination = goal
	plan.has_destination = true
	return true


## Approximates ability.is_in_range() from a HYPOTHETICAL position unit
## hasn't actually reached yet — the real is_in_range() always reads
## unit's true current global_position, which is no use for asking "if
## I finish this planned route, will I actually be close enough." Edge-
## to-edge, matching every real targeting subclass's own convention
## (Unit.edge_distance_to); ignores RangedEnemyTargeting's line-of-sight
## raycast entirely — see this file's header for why that's an accepted
## approximation here.
static func _would_be_in_range(position: Vector3, unit: Unit, target: Unit, ability: Ability) -> bool:
	var approach: float = ability.targeting.approach_range() if ability.targeting else 0.0
	var edge_distance: float = position.distance_to(target.global_position) - unit.radius - target.radius
	return edge_distance <= approach + 0.05


## Adds this plan's own tactical value on top of whatever score it
## already carries (an authored AiBehavior's own score_bonus, or 0.0 for
## a baseline-enumerated candidate) — see AiBehavior's own header for why
## behaviors only ever contribute a bias rather than a full absolute
## score: the actual expected-damage/expected-heal arithmetic is common
## to every candidate regardless of where it came from, so it lives here
## once instead of being re-derived per behavior.
static func _score_plan(unit: Unit, plan: AiPlan) -> void:
	var tier: int = unit.ai_smartness

	var expected_damage: float = 0.0
	var expected_heal: float = 0.0
	for effect in plan.ability.effects:
		expected_damage += effect.expected_damage(unit)
		expected_heal += effect.expected_heal(unit)

	var value: float = 0.0

	if expected_damage > 0.0 and plan.target is Unit:
		var chance: float = _chance_to_hit(unit, plan.target, plan.ability) if plan.ability.requires_to_hit else 1.0
		var hit_value: float = expected_damage * chance
		# Tier 0 never reaches here (see _feral_plan) — tier 1 already
		# wants "expected damage," which means clamping overkill from the
		# very first tier that reasons about damage at all, not something
		# gated to a later tier.
		value = minf(hit_value, float(plan.target.current_hp))

		if tier >= 2:
			if hit_value >= float(plan.target.current_hp):
				value += KILL_BONUS
			if plan.target.maximum_hp > 0:
				var missing_fraction: float = 1.0 - float(plan.target.current_hp) / float(plan.target.maximum_hp)
				value *= 1.0 + FINISH_WEIGHT * missing_fraction
	elif expected_heal > 0.0 and plan.target is Unit:
		var missing_hp: float = float(plan.target.maximum_hp - plan.target.current_hp)
		value = minf(expected_heal, missing_hp)

	plan.score += value

	# A tie-breaker, not a real tactical consideration — deliberately
	# tiny (never gated behind a smartness tier, never large enough to
	# outweigh an actual value difference): once overkill is clamped
	# above, a guaranteed-overkill nuke and a guaranteed-overkill basic
	# attack against the same target score identically otherwise, and
	# nothing should ever burn the pricier option to achieve the exact
	# same result.
	plan.score -= 0.001 * (plan.ability.move_cost + plan.ability.fp_cost)

	if tier >= 3 and plan.ability.fp_cost > 0.0 and float(unit.current_fp) - plan.ability.fp_cost < float(FP_RESERVE):
		plan.score -= FP_CONSERVE_PENALTY


## Nothing scored as usable this turn — rather than end the turn having
## done nothing, close distance toward the nearest hostile with whatever
## this unit would normally lead with (default_ability()). Concretely:
## a melee-only unit facing only airborne enemies has no feasible attack
## candidate at all (every one fails _resolve_reach), and previously just
## stood still for the rest of combat; this at least makes progress
## toward being in range for when the flyer descends or runs dry on FP
## (see FpDrainBehavior). Always returns a movement-only plan (has_
## destination already set, standoff-goal math identical to what a real
## candidate would have used) so CombatAI never mistakes this for an
## actionable ability — see that file's is_in_range branch, which this
## plan's has_destination deliberately routes around.
static func _fallback_plan(unit: Unit, tree: SceneTree) -> AiPlan:
	var target: Unit = UnitQuery.nearest_hostile(tree, unit)
	if not target:
		return null
	var ability: Ability = unit.default_ability()
	if not ability:
		return null

	var plan := AiPlan.new(ability, target)
	plan.with_destination(AiScorer.standoff_goal(unit, target, ability))
	return plan


## Expected damage unit would take before its next turn if it stood at
## position right now — the missing half of this scorer (see header):
## everything else here reasons about damage DEALT, this is the only
## place damage TAKEN is modeled. For each living hostile, takes that
## hostile's single best damage-dealing attack (same MeleeEnemyTargeting/
## RangedEnemyTargeting + expected_damage > 0 filter as
## _enumerate_baseline_candidates) times its chance to hit unit at
## position, and only counts it if the hostile could plausibly reach
## position this turn.
##
## Two deliberate approximations, same spirit as this file's other
## documented shortcuts:
## - Reach is a straight-line distance check (hostile's move_remaining +
##   the ability's approach_range vs edge distance to position), not a
##   real NavigationGrid.find_path — an A* search per hostile per ability
##   per candidate position is real cost for a number that only needs to
##   RANK candidates, not guarantee anything.
## - _chance_to_hit is evaluated with unit hypothetically AT position,
##   which needs the same temporary-adopt-and-restore _resolve_reach
##   already uses for flight_altitude: unit's real global_position is
##   swapped in, queried, and swapped back, so scoring one candidate can
##   never leak a hypothetical position into another candidate scored in
##   the same pass.
static func incoming_threat(unit: Unit, position: Vector3) -> float:
	var previous_position: Vector3 = unit.global_position
	unit.global_position = position

	var threat: float = 0.0
	for hostile in UnitQuery.living_units(unit.get_tree()):
		if not unit.is_hostile_to(hostile):
			continue

		var best_hit_value: float = 0.0
		for ability in hostile.abilities:
			if not ability.targeting:
				continue
			if not (ability.targeting is MeleeEnemyTargeting or ability.targeting is RangedEnemyTargeting):
				continue

			var total_damage: float = 0.0
			for effect in ability.effects:
				total_damage += effect.expected_damage(hostile)
			if total_damage <= 0.0:
				continue

			var reach: float = hostile.move_remaining + ability.targeting.approach_range()
			var edge_distance: float = hostile.global_position.distance_to(position) - hostile.radius - unit.radius
			if edge_distance > reach:
				continue

			var chance: float = _chance_to_hit(hostile, unit, ability) if ability.requires_to_hit else 1.0
			best_hit_value = max(best_hit_value, total_damage * chance)

		threat += best_hit_value

	unit.global_position = previous_position
	return threat


## Attacker's real to-hit target number against target for ability —
## same formula UnitCombat._roll_to_hit builds (own skill, outgoing
## modifiers, defender's incoming modifiers, altitude advantage), just
## converted to a probability instead of actually rolled. The to-hit term
## this produces DOES shift with altitude (AltitudeAdvantageBehavior caps
## at +4 — see altitude_advantage_behavior.gd), but that shift alone is
## second-order: against an already-likely-to-hit ranged attacker, +4
## buys only a few points of probability, nowhere near enough to justify
## a takeoff's cost on its own. The decisive reason to fly is captured
## separately, in incoming_threat() above — melee-only hostiles simply
## can't reach a unit that isn't on the ground.
static func _chance_to_hit(unit: Unit, target, ability: Ability) -> float:
	var target_number: int = unit.attack_skill()
	target_number += unit.outgoing_attack_to_hit_modifier(target, ability)
	if target is Unit:
		target_number += target.incoming_attack_to_hit_modifier(unit, ability)
		target_number += UnitCombat.ALTITUDE_ADVANTAGE.modify_incoming_attack_to_hit(target, unit, ability)
	return _success_probability(target_number)


## Exact 3d6-roll-under success probability against target_number —
## enumerates all 216 equally-likely outcomes rather than sampling, so
## this scorer's own decisions are deterministic and independent of RNG
## (a real roll still happens later, in UnitCombat.use_ability(), when
## the chosen plan is actually executed). Mirrors SuccessRoll.roll_vs's
## critical-success/critical-failure thresholds exactly — see that
## file's own doc comment for what each threshold means; duplicated
## here rather than refactored into one shared helper because
## SuccessRoll rolls dice and returns the roll, and this needs the
## opposite: a closed-form probability with no roll at all.
static func _success_probability(target_number: int) -> float:
	if _success_cache.has(target_number):
		return _success_cache[target_number]

	var success_count: int = 0
	for d1 in range(1, 7):
		for d2 in range(1, 7):
			for d3 in range(1, 7):
				var roll: int = d1 + d2 + d3
				var critical_success: bool = roll == 3 or roll == 4 \
					or (roll == 5 and target_number >= 15) \
					or (roll == 6 and target_number >= 16)
				var critical_failure: bool = not critical_success and (
					roll == 18
					or (roll == 17 and target_number <= 15)
					or roll >= target_number + 10
				)
				if critical_success or (not critical_failure and roll <= target_number):
					success_count += 1

	var probability: float = float(success_count) / 216.0
	_success_cache[target_number] = probability
	return probability


## The point a unit trying to act on target with ability should move to:
## just inside ability's range of target (see AbilityTargeting.
## approach_range — polymorphic, so this doesn't need to know which
## targeting subclass it's dealing with), not target's exact position
## (walking onto the same point another unit occupies is exactly what
## causes units to get physically stuck against each other).
##
## Lives here rather than on CombatAI (which used to own this) so every
## flight AI behavior (MaintainAltitude, FlyToCloseGap, ...) and this
## file's own reach-resolution can call it without CombatAI needing to
## depend on AiScorer at all — CombatAI already depends on AiScorer the
## other direction (for best_plan itself), and GDScript resolves a
## script's class_name dependencies eagerly, so a two-way dependency
## between an autoload script and a class it needs during its OWN
## bootstrap (see combat_ai.gd's registration as the "CombatAI"
## singleton) is a genuine load-order cycle, not just an style
## preference — confirmed by a real "Identifier not declared" parse
## error the first time this lived on CombatAI instead.
static func standoff_goal(unit: Unit, target: Unit, ability: Ability) -> Vector3:
	var to_target: Vector3 = target.global_position - unit.global_position
	var distance: float = to_target.length()
	if distance <= 0.001:
		return unit.global_position

	var direction: Vector3 = to_target / distance
	var ability_range: float = ability.targeting.approach_range() if ability.targeting else 0.0
	# Center-to-center distance at which this unit's *edge* sits exactly
	# at ability_range from target's edge (mirrors Unit.edge_distance_to).
	# The margin must exceed arrival_tolerance, not just be some small
	# constant — Unit's movement considers itself "arrived" (i.e. moves
	# no further) once within arrival_tolerance of the destination, so a
	# smaller margin lets it legitimately stop just outside range on the
	# very first approach, with no further progress possible on retry
	# (any remaining gap smaller than arrival_tolerance also counts as
	# "already arrived," so it would never move that last bit either).
	var margin: float = unit.arrival_tolerance + 0.05
	var standoff: float = max(ability_range + unit.radius + target.radius - margin, 0.05)
	return target.global_position - direction * standoff
