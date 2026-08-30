class_name AreaTargetBehavior
extends AiBehavior
## Proposes an area ability at the spot that catches the most hostiles —
## the controller's whole reason to exist, and the only way any of this
## project's area content is reachable by an AI at all.
##
## AiScorer's baseline enumeration covers unit-targeted melee and ranged
## abilities only; its header states outright that ground/area-targeted
## abilities are out of scope, because a point target has no obvious
## candidate to enumerate over. So explosive_fireball, grease, and every
## future AoE were unusable by every AI unit that owned them. This closes
## that gap by supplying the missing candidates: the enumeration a point
## target needs isn't over targets, it's over PLACES.
##
## Candidate points are the hostiles' own positions rather than a grid
## sweep. A blast centred on someone is close enough to optimal for a
## radius that comfortably exceeds unit spacing, and it costs O(hostiles)
## instead of O(cells) — the same "rank candidates, don't guarantee
## optimality" trade the rest of the scorer makes. It will miss the
## genuinely clever placement that catches three enemies while centred on
## none of them.
##
## Friendly fire is respected: a point is only offered if it catches at
## least min_targets hostiles AND no more than max_allies_caught allies,
## since AreaDamageEffect's affects_allies means a badly-placed blast can
## genuinely hit this unit's own side.

@export var ability: Ability
## Fewest hostiles a blast must catch to be worth proposing. 2 is the
## point of an AoE; 1 makes it compete with ordinary attacks, which is
## usually a waste of a limited resource.
@export var min_targets: int = 2
@export var max_allies_caught: int = 0
@export var bias: float = 0.0


func _propose_candidates(unit: Unit) -> Array[AiPlan]:
	if not ability or not ability.targeting:
		return []
	var radius: float = _blast_radius()
	if radius <= 0.0:
		return []

	var hostiles: Array[Unit] = []
	var allies: Array[Unit] = UnitQuery.living_allies(unit.get_tree(), unit)
	for other in UnitQuery.living_units(unit.get_tree()):
		if unit.is_hostile_to(other):
			hostiles.append(other)
	if hostiles.size() < min_targets:
		return []

	var plans: Array[AiPlan] = []
	for candidate in hostiles:
		var point: Vector3 = candidate.global_position

		var caught: int = 0
		for other in hostiles:
			if other.global_position.distance_to(point) <= radius:
				caught += 1
		if caught < min_targets:
			continue

		var friendly: int = 0
		for ally in allies:
			if ally.global_position.distance_to(point) <= radius:
				friendly += 1
		# This unit stands in its own blast too — easy to forget, and a
		# caster nuking itself is exactly the kind of "smart AI" moment
		# that reads as broken.
		if unit.global_position.distance_to(point) <= radius:
			friendly += 1
		if friendly > max_allies_caught:
			continue

		var plan: AiPlan = point_plan(unit, ability, point, bias)
		plan.reason = "area: %d caught" % caught
		plans.append(plan)

	return plans


## Radius from whichever targeting type this ability uses. AreaTargeting
## carries one directly; a GroundPointTargeting ability gets its radius
## from the AreaDamageEffect/AreaApplyStatusEffect doing the actual work,
## so fall through to the effects rather than assuming.
func _blast_radius() -> float:
	if ability.targeting is AreaTargeting:
		return ability.targeting.radius
	for effect in ability.effects:
		if "radius" in effect:
			return effect.radius
	return 0.0
