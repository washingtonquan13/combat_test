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
## A plan's score has two independent halves, scored separately and then
## added — WHAT it does and WHERE it leaves this unit standing:
##
##   action   — _score_plan: expected damage/heal, kill value, overkill
##              clamping, plus whatever bias the proposing behavior set.
##   position — _apply_positional_value: the change in score_position()
##              between where the unit stands now and where the plan ends
##              it up — the negated sustained_incoming_threat().
##
## Both are in the same currency (HP, over KILL_HORIZON_TURNS), and BOTH
## are applied by this file to every candidate. A behavior says where it
## wants to be and what it wants to do; it never prices either itself.
##
## The split exists because two real bugs came out of not having it.
## Earlier iterations assumed altitude reasoning "fell out for free"
## because AltitudeAdvantageBehavior shifts the to-hit number — it does,
## but that shift caps at +4 and is second-order next to simply being out
## of a melee attacker's reach. Fixing that by having each flight
## behavior call incoming_threat() itself then produced the second bug: a
## wounded flyer ground-fled rather than flying away, because within a
## SINGLE turn running ten meters is exactly as safe as flying, so the
## two candidates tied and a 0.001 ability-cost tie-breaker decided it.
## Position had to become a shared, sustained, multi-turn term before the
## arithmetic could say what the design always meant. See
## sustained_incoming_threat() and score_position() for each half of that.
##
## Deliberately NOT part of this: generic position enumeration (sampling
## candidate spots for a unit with no positioning behavior authored).
## Anything that sets AiPlan.destination gets priced, so the machinery is
## here, but authored behaviors remain the only source of destinations —
## adding a sampler means unbounded candidate counts and emergent
## movement that's hard to review, and it isn't needed for any current
## content.
##
## Known simplifications, not bugs: line of sight is ignored when
## checking whether a standoff point would land a ranged ability in
## range (an approximation of RangedEnemyTargeting's real LoS raycast —
## good enough to rank candidates, not to guarantee the final shot
## connects); this file's own BASELINE enumeration still covers only
## unit-targeted melee/ranged abilities, so ground/area-targeted ones
## (Fireball, Grease) reach the pool solely through AreaTargetBehavior,
## which supplies the candidate POINTS a blanket enumeration has no way
## to guess — _resolve_reach_at_current_altitude closes distance to them
## like any other target; "prefers
## targets that are dangerous," from the original design discussion, is
## no longer a dropped feature — see threat_output() and its use in
## _score_plan's kill-value term, which now prices exactly that.

## How many more turns a fight is assumed to last, for pricing "denying an
## enemy's future output" (killing it) or "losing this unit's own future
## output" (dying) in the same HP currency as every other score — see
## threat_output() and _score_plan's kill-value term below, and the
## survival term in _apply_positional_value. The one deliberately approximate,
## honestly-named magic number left in this file, replacing three
## unrelated ones (KILL_BONUS, FINISH_WEIGHT, FleeBehavior's flat 100.0)
## that each guessed at the same underlying idea in incompatible units.
const KILL_HORIZON_TURNS: float = 3.0
## Turns of damage still credited to a hostile that CAN eventually reach a
## position but needs longer than KILL_HORIZON_TURNS to get there — the
## "it's coming for me eventually" term, and what makes a unit take off
## PREEMPTIVELY rather than only once something is already on top of it.
##
## Without it the horizon is a hard cliff: a pursuer four turns out
## contributes exactly 0.0, so standing on open ground scores identically
## to hovering out of reach and a flyer has no reason to leave the ground
## until it's already in trouble. Deliberately small — a distant threat is
## a real reason to gain altitude, but a much weaker one than an adjacent
## one, and this must never rival the several-turns-of-damage figure a
## genuinely close hostile produces.
const DISTANT_REACHABLE_CREDIT: float = 0.5
## Tier 3 (Cunning) only — see that tier's own header line above.
const FP_RESERVE: int = 1
## Tier-3 nudge against spending FP down to nothing. Narrower than its
## original framing: the expensive half of running dry — the fall itself
## — is now computed exactly, at every tier, by _forced_descent_cost.
## What is left here is only the mild "don't cut it that fine"
## preference, so the two don't double-count.
const FP_CONSERVE_PENALTY: float = 3.0
## Below this, two candidates are considered tied on score and fall
## through to source_priority/enumeration_index instead — see
## _is_better(). Smaller than the 0.001 move/fp cost tie-breaker in
## _score_plan, so a real cost difference still decides before this
## does; exists so float noise never masquerades as a genuine score
## difference.
const SCORE_EPSILON: float = 0.0001

## _success_probability(target_number) memoized across calls within a
## single turn's worth of scoring (many candidates share the same
## attacker skill and often the same target) — 216 outcomes enumerated
## is cheap regardless, but the cache costs nothing either.
static var _success_cache: Dictionary = {}

## score_position() memoized WITHIN a single best_plan() pass only —
## many candidates share a destination (every attack against the same
## target resolves to the same standoff point), and each miss costs a
## full sweep over every hostile's abilities. Unlike _success_cache,
## which is keyed on a target number and stays valid forever, this is
## keyed on world positions that change the moment anything moves, so
## best_plan()/describe_candidates() clear it on entry rather than
## letting it persist across turns.
static var _position_cache: Dictionary = {}


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

	_position_cache.clear()

	var tree: SceneTree = unit.get_tree()
	var candidates: Array[AiPlan] = _enumerate_baseline_candidates(unit, tree)
	for behavior in unit.ai_behaviors:
		# BEHAVIOR_SOURCE_PRIORITY stamped here, not by each behavior,
		# so a behavior never has to remember to — a behavior expressing
		# a specific positional intent is strictly more informed than
		# the generic baseline enumeration above, so it should win a
		# genuine score tie (see _is_better).
		var proposed: Array[AiPlan] = behavior.propose(unit)
		for plan in proposed:
			plan.source_priority = BEHAVIOR_SOURCE_PRIORITY
		candidates.append_array(proposed)

	for i in candidates.size():
		candidates[i].enumeration_index = i

	var feasible: Array[AiPlan] = []
	for plan in candidates:
		if _prepare_plan(unit, plan):
			feasible.append(plan)

	if feasible.is_empty():
		return _fallback_plan(unit, tree)

	var best: AiPlan = feasible[0]
	for plan in feasible:
		if _is_better(plan, best):
			best = plan
	return best


## Source priority for a candidate produced by an authored AiBehavior — see
## best_plan's behavior loop and _is_better. Baseline-enumerated candidates
## (_enumerate_baseline_candidates) keep AiPlan.source_priority's default
## of 0.
const BEHAVIOR_SOURCE_PRIORITY: int = 10


## Debug dump of unit's full candidate pool, sorted best-first with each
## plan's score/source_priority/reason — the affordance whose absence
## made both the never-took-off and took-off-but-hovered bugs expensive
## to diagnose (each was worked out by hand-computing scores). Not called
## anywhere in normal play; a debug overlay or console command hooks in
## here.
static func describe_candidates(unit: Unit) -> String:
	_position_cache.clear()

	var tree: SceneTree = unit.get_tree()
	var candidates: Array[AiPlan] = _enumerate_baseline_candidates(unit, tree)
	for behavior in unit.ai_behaviors:
		var proposed: Array[AiPlan] = behavior.propose(unit)
		for plan in proposed:
			plan.source_priority = BEHAVIOR_SOURCE_PRIORITY
		candidates.append_array(proposed)
	for i in candidates.size():
		candidates[i].enumeration_index = i

	var feasible: Array[AiPlan] = []
	for plan in candidates:
		if _prepare_plan(unit, plan):
			feasible.append(plan)

	feasible.sort_custom(func(a, b): return _is_better(a, b))

	var lines: PackedStringArray = []
	for plan in feasible:
		var target_name: String = plan.target.get_display_name() if plan.target is Unit else str(plan.target)
		lines.append("%.3f [prio %d] %s -> %s : %s" % [
			plan.score, plan.source_priority,
			plan.ability.ability_name if plan.ability else "(none)",
			target_name, plan.reason
		])
	return "\n".join(lines)


## Deterministic replacement for "does a strictly beat the running best,"
## which used to mean silently, incidentally deciding every tie by array
## order — see this file's own header for the hover bug that caused.
## Resolves, in order: real score difference (beyond SCORE_EPSILON), then
## source_priority (a behavior's specific intent beats the generic
## baseline enumeration), then enumeration_index (lowest wins, so the
## result is reproducible rather than order-dependent).
static func _is_better(a: AiPlan, b: AiPlan) -> bool:
	if absf(a.score - b.score) > SCORE_EPSILON:
		return a.score > b.score
	if a.source_priority != b.source_priority:
		return a.source_priority > b.source_priority
	return a.enumeration_index < b.enumeration_index


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
	for other in UnitQuery.living_units_near(unit):
		if unit.is_hostile_to(other):
			hostiles.append(other)
	if hostiles.is_empty():
		return candidates

	for ability in _damaging_abilities(unit):
		for target in hostiles:
			candidates.append(AiPlan.new(ability, target))

	return candidates


## Every ability on unit that is a damage-dealing melee/ranged attack —
## the same MeleeEnemyTargeting/RangedEnemyTargeting + expected_damage > 0
## filter _enumerate_baseline_candidates and incoming_threat each used to
## duplicate inline. Factored out once both needed it a third time
## (threat_output below).
static func _damaging_abilities(unit: Unit) -> Array[Ability]:
	var abilities: Array[Ability] = []
	for ability in unit.abilities:
		if not ability.targeting:
			continue
		if not ability.targeting.targets_single_enemy():
			continue

		var total_damage: float = 0.0
		for effect in ability.effects:
			total_damage += effect.expected_damage(unit)
		if total_damage <= 0.0:
			continue

		abilities.append(ability)
	return abilities


## Expected damage unit deals per turn with its single best damage-dealing
## ability, against a representative hostile (the nearest one — good
## enough to rank candidates, same spirit as this file's other
## approximations; there is no "the" target before a plan is chosen).
## This is the conversion factor that prices "denying an enemy its future
## turns" (or losing this unit's own) in the same HP currency as every
## other score — see KILL_HORIZON_TURNS.
## Optionally evaluated from a hypothetical position rather than where the
## unit currently stands (same temporary-adopt-and-restore used
## throughout this file) — that's what lets a pure repositioning plan be
## credited for the attacks it will make BETTER from somewhere else, e.g.
## a flyer gaining AltitudeAdvantageBehavior's downward-fire bonus. Pass
## nothing for "from here."
static func threat_output(unit: Unit, position = null) -> float:
	var previous_position: Vector3 = unit.global_position
	if position != null:
		unit.global_position = position

	var representative: Unit = UnitQuery.nearest_hostile(unit.get_tree(), unit)
	var best: float = 0.0
	for ability in _damaging_abilities(unit):
		var total_damage: float = 0.0
		for effect in ability.effects:
			total_damage += effect.expected_damage(unit)
		var chance: float = 1.0
		if ability.requires_to_hit and representative:
			chance = _chance_to_hit(unit, representative, ability)
		best = max(best, total_damage * chance)

	if position != null:
		unit.global_position = previous_position
	return best


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
		if unit.in_combat() and ability.move_cost > 0.0 and unit.move_remaining < ability.move_cost:
			return false
		if ability.fp_cost > 0.0 and unit.current_fp < ability.fp_cost:
			return false
		if ability.targeting and ability.targeting.requires_ally_target() and plan.target is Unit and unit.is_hostile_to(plan.target):
			return false

	if not _resolve_reach(unit, plan):
		return false

	if not plan.pure_reposition:
		_score_plan(unit, plan)

	# Both remaining terms are applied HERE, to every candidate under one
	# rule, rather than inside _score_plan — which is skipped entirely for
	# a pure_reposition plan (see that branch above). That asymmetry was a
	# real, reproduced bug: a Flee's ground retreat paid no ability-cost
	# tie-breaker while the takeoff competing with it paid 0.001 x (2 move
	# + 1 FP), and since 0.003 is 30x SCORE_EPSILON, _is_better read it as
	# a genuine score difference and the source_priority tie-break never
	# ran. The wounded flyer ran away on foot every single time, decided
	# entirely by a term that exists only to separate two otherwise
	# identical plans.
	_apply_positional_value(unit, plan)

	# A tie-breaker, not a real tactical consideration — deliberately tiny
	# and never gated behind a smartness tier: once overkill is clamped
	# (see _score_plan), a guaranteed-overkill nuke and a guaranteed-
	# overkill basic attack against the same target score identically
	# otherwise, and nothing should ever burn the pricier option to
	# achieve the exact same result. A pure_reposition plan's `ability` is
	# a formality it never actually casts (see AiPlan.pure_reposition), so
	# it correctly contributes 0.0 here rather than being charged for a
	# cast that isn't happening.
	if not plan.pure_reposition:
		plan.score -= 0.001 * (plan.ability.move_cost + plan.ability.fp_cost)

	return true




## Adds how much better (or worse) it is to be standing where this plan
## ENDS than where the unit stands now — see score_position, which is
## safety-only and in the same HP currency as everything else.
##
## A delta rather than an absolute so a plan that doesn't move contributes
## exactly 0.0: standing still is the baseline every repositioning
## candidate is measured against, not a position that needs its own
## defense. Applied after _resolve_reach because THAT is what fills in
## plan.destination for a baseline candidate that has to walk into range
## (an authored behavior sets its own), so by here every plan knows where
## it actually ends up.
static func _apply_positional_value(unit: Unit, plan: AiPlan) -> void:
	var end_position: Vector3 = _plan_end_position(unit, plan)
	if end_position.is_equal_approx(unit.global_position):
		return

	var gain: float = score_position(unit, end_position) - score_position(unit, unit.global_position)

	# Offense BANKED rather than realized. A plan that attacks already
	# collects its positional advantage this turn — _score_plan evaluates
	# _chance_to_hit from this same end position, so altitude's to-hit
	# bonus is in its damage figure already, and crediting it again here
	# would double-count it. A plan that only MOVES (a takeoff, a pure
	# reposition) realizes nothing now; its offensive value is entirely
	# in the turns that follow, which is exactly why a takeoff used to
	# look worthless whenever nothing was currently threatening the unit.
	# Priced over the same horizon, and against the same representative
	# hostile, as every other future-value term in this file.
	if not _realizes_offense_this_turn(unit, plan):
		var offense_gain: float = (
			threat_output(unit, end_position) - threat_output(unit, unit.global_position)
		) * KILL_HORIZON_TURNS
		gain += offense_gain

	# SURVIVAL. Damage avoided (above) is only half of what moving out of
	# danger is worth: a unit that dies also stops contributing anything
	# for the rest of the fight. Exactly symmetric with the kill-value
	# term in _score_plan — killing an enemy denies its future output, and
	# dying forfeits your own — so it's priced the same way, over the same
	# horizon, in the same HP currency.
	#
	# This lived in FleeBehavior as a "death_premium" until the behavior
	# contract was tightened (see AiBehavior's header): it is a fact about
	# how much this unit stands to lose, not an authored preference, so a
	# behavior computing it was a behavior pricing its own plan. As a
	# DELTA it also fixes the flaw that version had — the old absolute
	# premium was added identically to every flee candidate, so fleeing
	# beat attacking even when running changed nothing about the danger.
	gain += threat_output(unit) * KILL_HORIZON_TURNS * (
		_death_probability(unit, unit.global_position) - _death_probability(unit, end_position)
	)

	gain -= _unsustainable_flight_cost(unit, plan, end_position)

	if absf(gain) < SCORE_EPSILON:
		return

	plan.score += gain
	if plan.reason == "":
		plan.reason = "reposition: %+.1f position" % gain
	else:
		plan.reason += " | %+.1f position" % gain


## Rough odds this unit dies before it acts again if it stands at
## position — sustained incoming damage against remaining HP, clamped to
## [0,1]. Reads the cached score_position() rather than re-sweeping every
## hostile, since that is the same figure negated.
static func _death_probability(unit: Unit, position: Vector3) -> float:
	var threat: float = -score_position(unit, position)
	return clampf(threat / max(float(unit.current_hp), 1.0), 0.0, 1.0)


## Whether this plan actually lands an attack this turn, and so has
## already had its positional offense counted by _score_plan — see
## _apply_positional_value's own comment on the double-count this avoids.
static func _realizes_offense_this_turn(unit: Unit, plan: AiPlan) -> bool:
	if plan.pure_reposition or not plan.ability or not plan.target is Unit:
		return false
	for effect in plan.ability.effects:
		if effect.expected_damage(unit) > 0.0:
			return true
	return false


## Where unit actually ends up if this plan is executed — usually just
## plan.destination, but a takeoff is the case that matters and has none.
##
## A takeoff never moves horizontally, so it carries no destination at
## all; its whole effect is a change in ALTITUDE, which is exactly the
## thing position scoring exists to price. Reading the height straight off
## the GrantFlightEffect (and clamping it the same way that effect's own
## apply() does) keeps the two from drifting: if scoring guessed a
## different altitude than the ability delivers, the AI would be choosing
## takeoffs on the strength of a benefit it never receives — which is
## precisely what fly.tres's takeoff_height of 1.0 was doing against
## behaviors that scored it as though it reached 8-10m.
##
## Landing is modeled too, via the same downward raycast UnitMovement.
## land() itself uses — this was left out of the first draft on the
## reasoning that the landing branch of the day already gated on nothing
## being able to reach the unit, so the delta would be ~0 by
## construction. Testing proved that wrong in the obvious way: that guard
## asked whether anything could reach the unit UP HERE and never what
## happened once it was down. An Avian hovering two meters over a melee
## brute reads as perfectly safe, lands directly into the brute's reach,
## and is hit for it. Pricing the real landing spot makes the descent
## cost what it actually costs.
static func _plan_end_position(unit: Unit, plan: AiPlan) -> Vector3:
	if plan.has_destination:
		return plan.destination

	if plan.ability:
		for effect in plan.ability.effects:
			if effect is GrantFlightEffect:
				# Clamped exactly the way GrantFlightEffect.apply() clamps
				# it, so scoring can't credit a takeoff with an altitude
				# the ability won't actually deliver.
				var target_y: float = clamp(
					unit.global_position.y + effect.takeoff_height,
					NavigationGrid.FLIGHT_MIN_ALTITUDE,
					NavigationGrid.FLIGHT_CEILING_HEIGHT
				)
				return Vector3(unit.global_position.x, target_y, unit.global_position.z)
			if effect is LandEffect:
				return Vector3(unit.global_position.x, _ground_y_at(unit, unit.global_position), unit.global_position.z)

	return unit.global_position




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
	# yet (HoldRangeBehavior's dive to melee range only makes sense
	# planned against the DIVE altitude, not wherever the unit currently
	# happens to be) — temporarily adopt it for this route
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
	var budget: float = unit.move_remaining if unit.in_combat() else INF

	# ACT IF YOU CAN, MOVE ONLY IF YOU MUST. An IF_NEEDED destination is
	# just "how I get in range" (see AiPlan.movement_intent), so once the
	# ability is already usable from here the move is pure cost — and,
	# worse, a move the unit may not be able to finish, which is exactly
	# how a flyer spent every turn drifting backwards toward an
	# unreachable altitude instead of shooting the party in front of it.
	#
	# Enforced HERE rather than in each behavior deliberately: this is the
	# rule every positional behavior has to get right, and the one a new
	# one will forget. Stripping the destination centrally means a
	# behavior can only opt OUT of it, by declaring REQUIRED.
	if (plan.has_destination
			and plan.movement_intent == AiPlan.MovementIntent.IF_NEEDED
			and not plan.pure_reposition
			and plan.ability
			and plan.target is Unit
			and plan.ability.is_in_range(unit, plan.target)):
		plan.has_destination = false

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
		# Ground/area-targeted: walk toward the point until it's in range.
		# Nothing produced these candidates until AreaTargetBehavior did
		# (this file's baseline enumeration covers unit-targeted abilities
		# only, and says so), so "out of scope" used to be an accurate
		# description rather than a limitation — now that a behavior
		# supplies them, refusing to close distance would leave every AoE
		# unusable unless the caster happened to already be in position.
		var point: Vector3 = plan.target
		var approach: float = plan.ability.targeting.approach_range() if plan.ability.targeting else 0.0
		var toward: Vector3 = point - unit.global_position
		var gap: float = toward.length()
		if gap <= 0.001:
			return true
		var point_goal: Vector3 = point - (toward / gap) * max(approach - unit.arrival_tolerance, 0.05)
		var point_route: Dictionary = unit.plan_route(point_goal, budget)
		if point_route.path.size() < 2:
			return false
		var landed: Vector3 = point_route.path[point_route.path.size() - 1]
		if landed.distance_to(point) > approach + 0.05:
			return false
		plan.destination = point_goal
		plan.has_destination = true
		return true

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
		# Evaluated from where the plan ENDS, not where the unit stands
		# now — same temporary-adopt-and-restore _resolve_reach uses for
		# flight_altitude, and for the same reason: this plan's whole
		# point may be to shoot from somewhere else. AltitudeAdvantage-
		# Behavior gives a ranged attacker up to +4 to-hit for firing
		# downward, so a flyer's climb to preferred_altitude is worth
		# real expected damage — but scored at the CURRENT position that
		# benefit was invisible, and a climb tied exactly with standing
		# still and shooting from here. Position scoring
		# (_apply_positional_value) deliberately covers only safety, so
		# offense-from-position has to be priced here or nowhere.
		var previous_position: Vector3 = unit.global_position
		unit.global_position = _plan_end_position(unit, plan)
		var chance: float = _chance_to_hit(unit, plan.target, plan.ability) if plan.ability.requires_to_hit else 1.0
		unit.global_position = previous_position

		var hit_value: float = expected_damage * chance
		# Tier 0 never reaches here (see _feral_plan) — tier 1 already
		# wants "expected damage," which means clamping overkill from the
		# very first tier that reasons about damage at all, not something
		# gated to a later tier.
		value = minf(hit_value, float(plan.target.current_hp))

		if tier >= 2 and hit_value >= float(plan.target.current_hp):
			# Denying the target its own future turns — priced in the
			# same HP currency as everything else via threat_output,
			# rather than a flat guess. A dangerous target is now worth
			# more to kill than a harmless one, and a target already
			# close to death collects this MORE OFTEN (less damage is
			# needed to cross current_hp) — the same "prefer finishing a
			# nearly-dead target" preference FINISH_WEIGHT used to
			# approximate by multiplying the base value, now falling out
			# for free instead of being double-counted.
			value += threat_output(plan.target) * KILL_HORIZON_TURNS
		if plan.reason == "":
			plan.reason = "attack: %.1f dmg%s" % [value, " (kills)" if hit_value >= float(plan.target.current_hp) else ""]
	elif expected_heal > 0.0 and plan.target is Unit:
		var missing_hp: float = float(plan.target.maximum_hp - plan.target.current_hp)
		value = minf(expected_heal, missing_hp)
		if plan.reason == "":
			plan.reason = "heal: %.1f hp" % value

	plan.score += value

	# The ability-cost tie-breaker used to live here; it now runs in
	# _prepare_plan so pure_reposition candidates are charged under the
	# same rule instead of being silently exempt — see that method.

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
	for hostile in UnitQuery.living_units_near(unit):
		if not unit.is_hostile_to(hostile):
			continue

		var best_hit_value: float = 0.0
		for ability in _damaging_abilities(hostile):
			var total_damage: float = 0.0
			for effect in ability.effects:
				total_damage += effect.expected_damage(hostile)

			var reach: float = hostile.move_remaining + ability.targeting.approach_range()
			var edge_distance: float = hostile.global_position.distance_to(position) - hostile.radius - unit.radius
			if edge_distance > reach:
				continue

			var chance: float = _chance_to_hit(hostile, unit, ability) if ability.requires_to_hit else 1.0
			best_hit_value = max(best_hit_value, total_damage * chance)

		threat += best_hit_value

	unit.global_position = previous_position
	return threat


## Expected damage taken at position over KILL_HORIZON_TURNS, rather than
## only before this unit's next turn (incoming_threat above) — the
## difference between "am I safe right now" and "is this a good place to
## be," and the reason a flyer can justify a takeoff at all.
##
## incoming_threat is a one-turn snapshot, and within one turn running ten
## meters is EXACTLY as safe as flying: both put a unit outside a melee
## pursuer's reach, both read 0.0, and the two candidates tie. That tie
## was a real, reproduced bug — a wounded Avian ground-fled every time,
## because nothing in the model could express "and it still can't reach
## me next turn, or ever." A pursuer that merely needs a turn to close
## gets counted for the remaining turns it WOULD be attacking; one that
## structurally cannot reach the position at all (see _can_ever_reach)
## contributes nothing, forever. That distinction is what makes altitude
## categorically different from distance instead of just more of it.
##
## Same two documented approximations as incoming_threat (straight-line
## reach rather than a real NavigationGrid.find_path, and _chance_to_hit
## evaluated with unit hypothetically adopted at position), for the same
## reason: this ranks candidates, it doesn't guarantee anything.
static func sustained_incoming_threat(unit: Unit, position: Vector3) -> float:
	var previous_position: Vector3 = unit.global_position
	unit.global_position = position

	var threat: float = 0.0
	for hostile in UnitQuery.living_units_near(unit):
		if not unit.is_hostile_to(hostile):
			continue

		var best_hit_value: float = 0.0
		for ability in _damaging_abilities(hostile):
			if not _can_ever_reach(hostile, position, ability):
				continue

			var total_damage: float = 0.0
			for effect in ability.effects:
				total_damage += effect.expected_damage(hostile)

			# Movement per turn, not move_remaining: this is a
			# multi-turn question, and whatever the hostile has left
			# THIS turn says nothing about how fast it closes over the
			# next three. Floored at 1.0 so a move-0 hostile that's
			# already in range still counts (it attacks from where it
			# stands) instead of dividing by zero.
			var move_per_turn: float = maxf(float(hostile.move), 1.0)
			var approach: float = ability.targeting.approach_range()
			var edge_distance: float = hostile.global_position.distance_to(position) - hostile.radius - unit.radius
			var turns_to_reach: float = ceilf(maxf(0.0, edge_distance - approach) / move_per_turn)
			var turns_attacking: float = maxf(0.0, KILL_HORIZON_TURNS - turns_to_reach)
			if turns_attacking <= 0.0:
				# Reachable, just not soon — everything that CAN'T reach
				# this position at all was already skipped by
				# _can_ever_reach above, so this branch is specifically
				# "a pursuer is on its way." See DISTANT_REACHABLE_CREDIT
				# for why that has to be worth something rather than
				# nothing: a hard horizon cliff means a flyer never takes
				# off until it's already cornered.
				turns_attacking = DISTANT_REACHABLE_CREDIT

			var chance: float = _chance_to_hit(hostile, unit, ability) if ability.requires_to_hit else 1.0
			best_hit_value = max(best_hit_value, total_damage * chance * turns_attacking)

		threat += best_hit_value

	unit.global_position = previous_position
	return threat


## Whether hostile could EVER bring ability to bear on position, as
## opposed to how long it would take — the term that makes being airborne
## categorically safe rather than merely distant.
##
## A grounded unit has to stand somewhere solid to swing: NavigationGrid.
## is_valid_cell()'s grounded rule requires solid support directly below
## (see ladder.gd's own header, which documents that rule in detail), so
## no grounded standoff point exists next to a target hovering above the
## attacker's own reach. Approximated as an O(1) height comparison rather
## than an actual route query — a real find_path per hostile per ability
## per candidate position is exactly the cost incoming_threat's header
## already declined to pay, and this only needs to rank candidates.
##
## Known limitation, same class as this file's other documented ones: it
## compares against the HOSTILE's current height, so it can't see terrain
## the hostile could climb onto to close the vertical gap. In an arena
## that never comes up; on a level with a tall platform beside a hovering
## flyer, this will overrate that flyer's safety.
static func _can_ever_reach(hostile: Unit, position: Vector3, ability: Ability) -> bool:
	if hostile.is_flying() or FlightAiUtil.find_flight_ability(hostile):
		return true
	var approach: float = ability.targeting.approach_range() if ability.targeting else 0.0
	return position.y - hostile.global_position.y <= approach


## How good it is for unit to be standing at position, in the same HP
## currency as every other score — deliberately SAFETY ONLY (the negated
## sustained threat), never "and how well could I attack from here."
##
## That asymmetry is the whole point of splitting position scoring out:
## offense is already the action half of a plan's score (see _score_plan's
## expected-damage arithmetic), so folding reach in here would count it
## twice. Position answers one question — what does standing here cost me
## — and _prepare_plan adds the DELTA between a plan's destination and
## where the unit already stands, so a plan that doesn't move contributes
## exactly 0.0 rather than being penalized for existing.
##
## Before this existed, every behavior that cared about position
## hand-rolled its own threat delta (MaintainAltitude did it three times,
## Flee twice) and each one competed against the others' arithmetic on an
## unstated scale. Now they only express WHERE they want to be, same
## division of labor AiBehavior's own header describes for abilities.
static func score_position(unit: Unit, position: Vector3) -> float:
	var key: Array = [unit.get_instance_id(), position]
	if _position_cache.has(key):
		return _position_cache[key]
	var value: float = -(sustained_incoming_threat(unit, position) + _forced_descent_cost(unit, position))
	_position_cache[key] = value
	return value


## What taking off costs when the unit can't afford to stay up once it
## gets there — the mirror of _forced_descent_cost, for the one case that
## function structurally cannot see.
##
## _forced_descent_cost reasons from unit.is_flying(), so a GROUNDED unit
## weighing a takeoff pays nothing for flight it cannot sustain: it isn't
## airborne yet, so there's no descent to anticipate. That let an Avian
## with a single FP spend it on Fly, reach three metres, and be dropped
## again on the very next turn for fall damage — all cost, no benefit,
## and obviously silly to anyone watching.
##
## Charges the fall the takeoff is buying, whenever the FP left AFTER
## paying for the ability can't cover even one turn aloft. Scored rather
## than forbidden, because the arithmetic already knows what flight is
## worth here: if being airborne genuinely saves more than the fall costs
## (a cornered unit escaping something lethal), it still wins, and the
## rest of the time it correctly doesn't bother.
static func _unsustainable_flight_cost(unit: Unit, plan: AiPlan, end_position: Vector3) -> float:
	if unit.is_flying() or plan.pure_reposition or not plan.ability:
		return 0.0

	var upkeep: int = FlightAiUtil.prospective_flight_upkeep(plan.ability)
	if upkeep <= 0:
		return 0.0

	var remaining: float = float(unit.current_fp) - plan.ability.fp_cost
	var turns_aloft: float = remaining / float(upkeep)
	if turns_aloft >= KILL_HORIZON_TURNS:
		return 0.0

	var ground_y: float = _ground_y_at(unit, end_position)
	var descent: float = maxf(0.0, end_position.y - ground_y)

	var cost: float = 0.0
	var roll: Dictionary = UnitMovement.FLIGHT_RULES.fall_damage_for_descent(descent)
	if roll.dice_count > 0:
		cost = float(roll.dice_count) * 3.5 + float(roll.dice_bonus)
		if UnitMovement.FLIGHT_RULES.fall_damage_reduced_by_dr:
			cost = maxf(0.0, cost - float(unit.damage_reduction))

	# And the safety it's buying is only rented. _apply_positional_value
	# has already credited this takeoff with escaping everything that
	# can't reach it up there — for the FULL horizon, because
	# score_position has no way to know the unit can't pay to stay. Give
	# back the share of that credit it hasn't actually earned, or a bird
	# with one FP happily buys three turns of safety it gets one turn of.
	var grounded_fraction: float = 1.0 - turns_aloft / KILL_HORIZON_TURNS
	cost += sustained_incoming_threat(
		unit, Vector3(end_position.x, ground_y, end_position.z)) * grounded_fraction
	return cost


## What being airborne at position really costs once you account for not
## being able to STAY there — the fall when the FP runs out, plus the time
## spent on the ground afterwards.
##
## This is the correction to a comparison the scorer was getting wrong in
## a way players would read as suicidal. Hovering scores as near-perfectly
## safe against grounded melee, standing scores as dangerous, so landing
## always looked like a downgrade and a flyer would sooner take a lethal
## fall than descend. But the two are not alternatives: a flyer that runs
## dry is dropped ON THE SPOT (FpDrainBehavior removes the status in
## place, routing through ForceLandOnExpireBehavior into Unit.land(false)
## and a full fall-damage roll). It ends up on exactly the ground it was
## refusing to land on, having paid extra for the privilege.
##
## So the ground's danger is not avoided by staying up — only DEFERRED,
## by however many turns the remaining FP buys. Charging the airborne
## position for the fall, plus the fraction of the horizon it will spend
## grounded anyway, makes the two options finally comparable:
##
##   land now  = ground threat
##   stay up   = fall damage + ground threat x (the horizon it can't cover)
##
## which leaves landing better by exactly the fall it avoids, except when
## the ground below is dangerous enough that buying time is worth taking
## the hit. That is the real tradeoff, and it now falls out of the
## arithmetic instead of needing a rule.
static func _forced_descent_cost(unit: Unit, position: Vector3) -> float:
	if not unit.is_flying():
		return 0.0
	var upkeep: int = FlightAiUtil.flight_upkeep(unit)
	if upkeep <= 0:
		return 0.0

	var turns_aloft: float = float(unit.current_fp) / float(upkeep)
	if turns_aloft >= KILL_HORIZON_TURNS:
		return 0.0

	var ground_y: float = _ground_y_at(unit, position)
	var descent: float = maxf(0.0, position.y - ground_y)
	# Already at ground level: nothing to fall from, and the threat here is
	# what sustained_incoming_threat just measured — adding it again would
	# double-count and make every landing look worse than it is.
	if descent <= UnitMovement.FLIGHT_RULES.safe_fall_distance:
		return 0.0

	var cost: float = 0.0
	var roll: Dictionary = UnitMovement.FLIGHT_RULES.fall_damage_for_descent(descent)
	if roll.dice_count > 0:
		cost = float(roll.dice_count) * 3.5 + float(roll.dice_bonus)
		if UnitMovement.FLIGHT_RULES.fall_damage_reduced_by_dr:
			cost = maxf(0.0, cost - float(unit.damage_reduction))

	var grounded_fraction: float = 1.0 - turns_aloft / KILL_HORIZON_TURNS
	cost += sustained_incoming_threat(unit, Vector3(position.x, ground_y, position.z)) * grounded_fraction
	return cost




## Height of whatever solid surface sits under position — same downward
## raycast Unit.land() uses to find where a descent actually ends (see
## UnitMovement.land's own header on why a raycast rather than a
## NavigationGrid lookup). Returns position.y when there's nothing below,
## so a flyer out over a void reads as zero descent rather than an
## infinite one: land() itself refuses to move in that case.
static func _ground_y_at(unit: Unit, position: Vector3) -> float:
	if not unit.is_inside_tree():
		return position.y

	var exclude: Array[RID] = []
	for other in UnitQuery.all_units_near(unit):
		# Skip anything already on its way out. A queue_free()d unit stays
		# in its group for the rest of the frame but its physics RID is
		# already gone, and handing a dangling RID to the physics server
		# takes the whole process down with a segfault rather than an
		# error — found by a unit dying on the turn before this ran.
		if not is_instance_valid(other) or not other.is_inside_tree():
			continue
		exclude.append(other.get_rid())

	var space_state := unit.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(position, position + Vector3.DOWN * 200.0)
	query.exclude = exclude
	var result: Dictionary = space_state.intersect_ray(query)
	if result.is_empty():
		return position.y
	return result.position.y


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
