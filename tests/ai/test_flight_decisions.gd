extends AiTestCase
## Every flight decision that shipped wrong at least once. These are the
## regressions with the most history behind them — each one is a bug a
## player actually saw.


func run() -> void:
	_takes_off_when_it_should()
	_declines_when_it_should()
	_fights_instead_of_running()
	_flees_by_air()
	_lands_before_falling()


func _takes_off_when_it_should() -> void:
	# Bug: an authored flyer never left the ground, because a flat 1.0
	# takeoff bonus lost to a 1.35 damage figure with nothing converting
	# between them.
	var avian: Unit = spawn_demon("avian", Vector3.ZERO)
	var brute: Unit = spawn_brute(1.0)
	var plan: AiPlan = AiScorer.best_plan(avian)
	check("grounded flyer with a melee attacker adjacent takes off",
		plan != null and plan.ability == FlightAiUtil.find_flight_ability(avian),
		"chose %s" % (plan.reason if plan else "nothing"))
	free_spawned()


func _declines_when_it_should() -> void:
	# Bug: it spent its last FP on flight it could not hold, reached three
	# metres, and was dropped again next turn for fall damage.
	var broke: Unit = spawn_demon("avian", Vector3.ZERO, false, 1)
	var brute: Unit = spawn_brute(1.5)
	var plan: AiPlan = AiScorer.best_plan(broke)
	check("a flyer with one FP does NOT take off",
		plan != null and plan.ability != FlightAiUtil.find_flight_ability(broke),
		"chose %s" % (plan.reason if plan else "nothing"))
	free_spawned()

	var funded: Unit = spawn_demon("avian", Vector3.ZERO, false, 8)
	var other: Unit = spawn_brute(1.5)
	var funded_plan: AiPlan = AiScorer.best_plan(funded)
	check("a flyer with a full bar still takes off",
		funded_plan != null and funded_plan.ability == FlightAiUtil.find_flight_ability(funded),
		"chose %s" % (funded_plan.reason if funded_plan else "nothing"))
	free_spawned()


func _fights_instead_of_running() -> void:
	# Bug: outnumbered and at full health, it spent every turn drifting
	# backwards toward an unreachable altitude and never once attacked.
	var avian: Unit = spawn_demon("avian", Vector3(0.0, 8.0, 0.0), true, 8)
	if not avian.is_flying():
		check("SKIP guard: flying status applied", false, "is_flying() false")
		free_spawned()
		return
	for i in 4:
		spawn_brute(3.0 + i * 1.5)

	var plan: AiPlan = AiScorer.best_plan(avian)
	check("healthy and outnumbered 4-to-1, it attacks rather than repositioning",
		plan != null and not plan.has_destination and not plan.pure_reposition
			and plan.target is Unit,
		"chose %s" % (plan.reason if plan else "nothing"))
	free_spawned()


func _flees_by_air() -> void:
	# Bug: a wounded flyer ran away on foot, because within one turn
	# running ten metres is exactly as safe as flying — the tie was then
	# broken by a 0.003 ability-cost term.
	var avian: Unit = spawn_demon("avian", Vector3.ZERO, false, 8)
	avian.current_hp = 1
	var brute: Unit = spawn_brute(1.5)

	var flee: AiBehavior = behavior_of(avian, func(b): return b is FleeBehavior)
	check("the aerial archetype carries a flee behavior", flee != null)
	if flee == null:
		free_spawned()
		return

	var takeoff: float = -INF
	var retreat: float = -INF
	for plan in score_proposals(avian, flee.propose(avian)):
		if plan.pure_reposition:
			retreat = plan.score
		else:
			takeoff = plan.score
	check("a wounded flyer's air escape beats its ground escape by a real margin",
		takeoff - retreat > 1.0, "takeoff %.2f vs retreat %.2f" % [takeoff, retreat])
	free_spawned()


func _lands_before_falling() -> void:
	# Bug: it would rather take lethal fall damage than land. Two causes —
	# the turn ended on the free Land action (see test_turn_economy), and
	# nothing priced being dropped where it hovered.
	var over_safe_ground: Unit = spawn_demon("avian", Vector3(0.0, 8.0, 0.0), true, 1)
	if not over_safe_ground.is_flying():
		check("SKIP guard: flying status applied", false, "is_flying() false")
		free_spawned()
		return
	var distant: Unit = spawn_brute(40.0)
	var plan: AiPlan = AiScorer.best_plan(over_safe_ground)
	check("low on FP over safe ground, it lands",
		plan != null and plan.reason.begins_with("land"),
		"chose %s" % (plan.reason if plan else "nothing"))
	free_spawned()

	# ...but not into the thing that drove it up there. Buying a turn is
	# worth the fall when the ground is lethal.
	var over_a_crowd: Unit = spawn_demon("avian", Vector3(0.0, 8.0, 0.0), true, 1)
	for i in 3:
		spawn_brute(2.0 + i * 1.5)
	var crowded: AiPlan = AiScorer.best_plan(over_a_crowd)
	check("low on FP over a crowd, it does not land straight into it",
		crowded != null and not crowded.reason.begins_with("land"),
		"chose %s" % (crowded.reason if crowded else "nothing"))
	free_spawned()

	var comfortable: Unit = spawn_demon("avian", Vector3(0.0, 8.0, 0.0), true, 8)
	var one: Unit = spawn_brute(3.0)
	var no_landing: AiPlan = AiScorer.best_plan(comfortable)
	check("with FP to spare, landing is not proposed at all",
		no_landing != null and not no_landing.reason.begins_with("land"),
		"chose %s" % (no_landing.reason if no_landing else "nothing"))
	free_spawned()
