extends AiTestCase
## AiScorer's two halves — what a plan DOES (_score_plan) and where it
## LEAVES you (_apply_positional_value) — plus the tie-breaking that
## decides between candidates the arithmetic rates equally.


func run() -> void:
	_threat_output()
	_kill_value()
	_downed_targets()
	_sustained_threat()
	_tie_breaking()
	_positional_value()
	_no_state_left_behind()


func _threat_output() -> void:
	var strong: Unit = spawn_unit(&"enemy", 16, 10, 10, [melee()], Vector3.ZERO)
	var weak: Unit = spawn_unit(&"enemy", 8, 10, 10, [ranged()], Vector3(1.0, 0.0, 0.0))
	var dummy: Unit = spawn_brute(4.0)
	check("threat_output scales with ST",
		AiScorer.threat_output(strong) > AiScorer.threat_output(weak))

	var before: Vector3 = weak.global_position
	AiScorer.threat_output(weak, Vector3(0.0, 9.0, 0.0))
	check("threat_output(position) restores the unit's real position",
		weak.global_position.is_equal_approx(before))

	# A low-skill shooter gains from AltitudeAdvantageBehavior; a DX-16
	# one is already at the 3d6 ceiling and gains nothing, which is why
	# this uses a deliberately mediocre archer.
	var archer: Unit = spawn_unit(&"enemy", 10, 9, 10, [ranged()], Vector3.ZERO)
	var target: Unit = spawn_brute(5.0)
	check("threat_output is higher from altitude for a ranged attacker",
		AiScorer.threat_output(archer, Vector3(0.0, 9.0, 0.0)) > AiScorer.threat_output(archer))
	free_spawned()


func _kill_value() -> void:
	# Targets on the enemy side: the party goes Downed below 0 instead of
	# dying, so a 1-HP party member is not a kill. ST 16 so the expected
	# hit, after the target's active defense, still clears 1 HP.
	var attacker: Unit = spawn_unit(&"player", 16, 12, 10, [melee()], Vector3.ZERO)
	var dangerous: Unit = spawn_unit(&"enemy", 16, 10, 1, [melee()], Vector3(1.0, 0.0, 0.0))
	var harmless: Unit = spawn_unit(&"enemy", 8, 10, 1, [], Vector3(1.0, 0.0, 1.0))

	var against_dangerous := AiPlan.new(melee(), dangerous)
	AiScorer._score_plan(attacker, against_dangerous)
	var against_harmless := AiPlan.new(melee(), harmless)
	AiScorer._score_plan(attacker, against_harmless)
	check("killing a dangerous target beats killing a harmless one",
		against_dangerous.score > against_harmless.score,
		"%.3f vs %.3f" % [against_dangerous.score, against_harmless.score])
	free_spawned()



## A Downed unit threatens nothing, is still worth finishing, and is
## worth more the closer it is to its third mark.
func _downed_targets() -> void:
	var attacker: Unit = spawn_unit(&"enemy", 12, 12, 10, [melee()], Vector3.ZERO)
	var downed: Unit = spawn_unit(&"player", 12, 12, 10, [melee()], Vector3(1.0, 0.0, 0.0))
	downed.set_pool(StatIds.HP, -3)
	downed.apply_status(UnitCombat.downed_status())

	check_equalf("a Downed unit has no threat output", AiScorer.threat_output(downed), 0.0)
	check("but a latent one", AiScorer.latent_threat_output(downed) > 0.0)
	check_equalf("a Downed hostile adds no incoming threat",
		AiScorer.incoming_threat(attacker, Vector3.ZERO), 0.0)
	check("only Downed left: it's still the nearest hostile",
		UnitQuery.nearest_hostile(attacker.get_tree(), attacker) == downed)

	var first_mark := AiPlan.new(melee(), downed)
	AiScorer._score_plan(attacker, first_mark)
	downed.downed_tally()["death"] = 2
	var last_mark := AiPlan.new(melee(), downed)
	AiScorer._score_plan(attacker, last_mark)
	check("the last mark is worth more than the first",
		last_mark.score > first_mark.score and first_mark.score > 0.0,
		"%.3f vs %.3f" % [last_mark.score, first_mark.score])

	var standing: Unit = spawn_unit(&"player", 12, 12, 10, [melee()], Vector3(4.0, 0.0, 0.0))
	check("a standing hostile comes before a nearer Downed one",
		UnitQuery.nearest_hostile(attacker.get_tree(), attacker) == standing)

	var finish := load("res://data/ai_behaviors/finish_downed.tres") as FinishDownedBehavior
	var brute: AiArchetype = load("res://data/ai_archetypes/brute.tres")
	check("archetypes carry the personality bias", finish != null and brute.behaviors.has(finish))
	check("a Scary demon leans toward finishing, a Kind one doesn't",
		finish.bias_by_personality.get(&"Scary", 0.0) > 0.0 and finish.bias_by_personality.get(&"Kind", 0.0) == 0.0)
	free_spawned()

## The term that makes altitude categorically different from distance:
## running is a delay, being unreachable is permanent.
func _sustained_threat() -> void:
	var avian: Unit = spawn_demon("avian", Vector3.ZERO)
	var brute: Unit = spawn_brute(1.5)

	var adjacent: float = AiScorer.sustained_incoming_threat(avian, Vector3.ZERO)
	var far: float = AiScorer.sustained_incoming_threat(avian, Vector3(-10.0, 0.0, 0.0))
	var airborne: float = AiScorer.sustained_incoming_threat(avian, Vector3(0.0, 8.0, 0.0))

	check("adjacent > distant > airborne", adjacent > far and far > airborne,
		"%.2f / %.2f / %.2f" % [adjacent, far, airborne])
	check_equalf("airborne vs melee-only is exactly zero", airborne, 0.0)
	check("a distant pursuer still counts for something", far > 0.0, "%.3f" % far)

	check("_can_ever_reach: grounded melee cannot reach an airborne spot",
		not AiScorer._can_ever_reach(brute, Vector3(0.0, 8.0, 0.0), melee()))
	check("_can_ever_reach: grounded melee can reach a ground spot",
		AiScorer._can_ever_reach(brute, Vector3.ZERO, melee()))
	free_spawned()

	# Altitude reduces a ranged attacker's odds but never removes them.
	var bird: Unit = spawn_demon("avian", Vector3.ZERO)
	var archer: Unit = spawn_unit(&"player", 16, 13, 20, [ranged()], Vector3(4.0, 0.0, 0.0))
	var on_ground: float = AiScorer.sustained_incoming_threat(bird, Vector3.ZERO)
	var up_high: float = AiScorer.sustained_incoming_threat(bird, Vector3(0.0, 3.0, 0.0))
	check("vs ranged, altitude reduces threat but never zeroes it",
		up_high > 0.0 and up_high < on_ground, "%.3f vs %.3f" % [up_high, on_ground])
	free_spawned()


## Two candidates the arithmetic rates equally must not be decided by
## which one happened to be appended first — the bug that left a flyer
## hovering in place forever.
func _tie_breaking() -> void:
	var baseline := AiPlan.new(melee(), null)
	baseline.score = 5.0
	var authored := AiPlan.new(melee(), null)
	authored.score = 5.0
	authored.source_priority = AiScorer.BEHAVIOR_SOURCE_PRIORITY
	authored.enumeration_index = 1

	check("a behavior's candidate beats the baseline at equal score",
		AiScorer._is_better(authored, baseline) and not AiScorer._is_better(baseline, authored))

	baseline.enumeration_index = 1
	authored.enumeration_index = 0
	check("and still does with the pool order reversed",
		AiScorer._is_better(authored, baseline) and not AiScorer._is_better(baseline, authored))


func _positional_value() -> void:
	var attacker: Unit = spawn_unit(&"enemy", 12, 12, 10, [melee()], Vector3.ZERO)
	var target: Unit = spawn_brute(1.5)
	var stationary := AiPlan.new(melee(), target)
	AiScorer._apply_positional_value(attacker, stationary)
	check_equalf("a plan that doesn't move gets exactly zero positional value",
		stationary.score, 0.0)
	free_spawned()

	# The ability-cost tie-breaker must live OUTSIDE _score_plan, which is
	# skipped entirely for pure_reposition plans. While it was inside, a
	# flee paid nothing while the takeoff competing with it paid 0.003 —
	# and since that exceeds SCORE_EPSILON it read as a real score
	# difference and decided between them. A wounded flyer ran away on
	# foot every time because of it.
	#
	# Asserted behaviourally rather than by grepping the source: Fly costs
	# 2 movement and 1 FP and deals no damage, so if _score_plan still
	# applied the tie-breaker this plan would come out at -0.003 rather
	# than exactly zero.
	var flyer: Unit = spawn_demon("avian", Vector3.ZERO)
	var nearby: Unit = spawn_brute(2.0)
	var takeoff := AiPlan.new(FlightAiUtil.find_flight_ability(flyer), flyer)
	AiScorer._score_plan(flyer, takeoff)
	check_equalf("_score_plan does not apply the ability-cost tie-breaker",
		takeoff.score, 0.0, 0.0001)
	free_spawned()


## Everything hypothetical in AiScorer adopts state and restores it. A
## full pass must leave the unit exactly as it found it, or one
## candidate's guess leaks into the next one's score.
func _no_state_left_behind() -> void:
	var avian: Unit = spawn_demon("avian", Vector3(1.0, 0.0, 2.0))
	var brute: Unit = spawn_brute(3.0, 2.0)
	var position: Vector3 = avian.global_position
	var altitude: float = avian.flight_target_altitude

	AiScorer.best_plan(avian)

	check("best_plan restores global_position", avian.global_position.is_equal_approx(position))
	check_equalf("best_plan restores flight_target_altitude",
		avian.flight_target_altitude, altitude)
	free_spawned()
