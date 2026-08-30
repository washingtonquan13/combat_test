extends AiTestCase
## AiBehavior's contract: propose candidates and an authored bias, never
## price, never decide, never reposition when already able to act.
## Each check here corresponds to a bug that shipped from breaking it.


func run() -> void:
	_movement_intent()
	_bias_ceiling()
	_no_behavior_prices_itself()


func _movement_intent() -> void:
	var attacker: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3.ZERO)
	var target: Unit = spawn_brute(1.0)

	# The flyer that spent every turn drifting toward an altitude it could
	# not afford to reach, while the party stood in range below it.
	var if_needed := AiPlan.new(melee(), target)
	if_needed.with_destination(Vector3(50.0, 0.0, 50.0))
	AiScorer._resolve_reach(attacker, if_needed)
	check("IF_NEEDED plan already in range loses its destination",
		not if_needed.has_destination)

	# ...but a flee or a withdrawal must still be able to move on purpose.
	var required := AiPlan.new(melee(), target)
	required.with_destination(Vector3(3.0, 0.0, 0.0))
	required.movement_intent = AiPlan.MovementIntent.REQUIRED
	AiScorer._resolve_reach(attacker, required)
	check("REQUIRED plan keeps its destination even when in range",
		required.has_destination)

	check("IF_NEEDED is the default", AiPlan.new().movement_intent
		== AiPlan.MovementIntent.IF_NEEDED)
	free_spawned()


func _bias_ceiling() -> void:
	check("MAX_AUTHORED_BIAS stays small enough to be a bias",
		AiBehavior.MAX_AUTHORED_BIAS <= 10.0,
		"%.1f" % AiBehavior.MAX_AUTHORED_BIAS)


## Every authored bias across every shipped archetype must sit under the
## ceiling. A behavior above it is computing value rather than expressing
## preference, which is how a takeoff once outvoted the arithmetic that
## had correctly judged it a bad idea.
func _no_behavior_prices_itself() -> void:
	var offenders: PackedStringArray = []
	for file in DirAccess.get_files_at("res://data/ai_archetypes"):
		if not file.ends_with(".tres"):
			continue
		var archetype: AiArchetype = load("res://data/ai_archetypes/%s" % file)
		for behavior in archetype.behaviors:
			for property in ["bias", "flight_preference", "score_bonus", "bias_per_ally"]:
				if property in behavior and absf(behavior.get(property)) > AiBehavior.MAX_AUTHORED_BIAS:
					offenders.append("%s.%s=%.1f" % [file, property, behavior.get(property)])
	check("no shipped archetype authors a bias above the ceiling",
		offenders.is_empty(), ", ".join(offenders))
