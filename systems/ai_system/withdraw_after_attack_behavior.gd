class_name WithdrawAfterAttackBehavior
extends AiBehavior
## The skirmisher's signature: having already struck this turn, give
## ground rather than standing in reach waiting to be struck back. The
## textbook description of the role — skirmishers "rely on their mobility
## to quickly move in and make calculated melee attacks before falling
## back."
##
## Only proposes once the attack action is spent (Unit.has_attacked), so
## it can never compete with attacking — it fills the part of a turn that
## would otherwise be wasted. That ordering is what makes strike-then-
## withdraw fall out of two independent candidates instead of needing a
## scripted two-phase action: CombatAI re-asks for a plan after every
## completed move and after the attack resolves (see
## combat_ai._on_movement_finished), so the withdrawal is simply the best
## remaining option on the second ask.
##
## Pure repositioning, so it costs no ability and can't be blocked by a
## spent action or empty FP — see AiPlan.pure_reposition. Whether giving
## ground is actually worth the remaining movement is
## AiScorer._apply_positional_value's call, as always: a skirmisher that
## struck something harmless, or that has nowhere safer to stand, simply
## scores the withdrawal near zero and stays put.

## How far to fall back, in metres of remaining movement. The whole point
## is to leave the enemy's reach, so the useful setting is a little more
## than the melee range being escaped.
@export var withdraw_distance: float = 6.0
@export var bias: float = 0.0


func _propose_candidates(unit: Unit) -> Array[AiPlan]:
	if not unit.has_attacked:
		return []
	if not unit.has_move_remaining():
		return []

	var hostiles: Array[Unit] = []
	for other in UnitQuery.living_units(unit.get_tree()):
		if unit.is_hostile_to(other):
			hostiles.append(other)
	if hostiles.is_empty():
		return []

	# Away from the centroid rather than from whoever was just hit — the
	# same reasoning FleeBehavior uses: backing away from one attacker
	# into a second one's reach is not a withdrawal.
	var centroid: Vector3 = Vector3.ZERO
	for hostile in hostiles:
		centroid += hostile.global_position
	centroid /= hostiles.size()

	var away: Vector3 = unit.global_position - centroid
	away.y = 0.0
	if away.length() < 0.01:
		away = Vector3.FORWARD
	away = away.normalized()

	var plan: AiPlan = reposition_plan(
		unit, hostiles[0], unit.global_position + away * withdraw_distance, bias)
	plan.reason = "withdraw after strike"
	return [plan]
