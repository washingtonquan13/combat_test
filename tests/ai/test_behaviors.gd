extends AiTestCase
## The individual behaviors in the archetype suite, each exercised on the
## situation it exists for.


func run() -> void:
	_hold_range()
	_area_target()
	_focus_fire()
	_support_ally()
	_withdraw_after_attack()
	_land_before_exhaustion()


## The capability nothing in this project had before: backing away
## horizontally from a melee attacker that has closed on a shooter.
func _hold_range() -> void:
	var behavior := HoldRangeBehavior.new()
	behavior.preferred_range = 9.0
	behavior.range_tolerance = 2.0

	var archer: Unit = spawn_unit(&"enemy", 10, 12, 20, [ranged()], Vector3.ZERO)
	var closed_in: Unit = spawn_brute(1.5)
	var retreat: Array[AiPlan] = behavior.propose(archer)
	check("backs away from an attacker inside its preferred range",
		retreat.size() == 1 and retreat[0].reason.begins_with("withdraw")
			and retreat[0].destination.distance_to(closed_in.global_position)
				> archer.global_position.distance_to(closed_in.global_position),
		"proposed %s" % (retreat[0].reason if retreat.size() else "nothing"))
	remove_spawned(closed_in)

	var distant: Unit = spawn_brute(40.0)
	var advance: Array[AiPlan] = behavior.propose(archer)
	check("closes on a target beyond its preferred range",
		advance.size() == 1 and advance[0].reason.begins_with("close"),
		"proposed %s" % (advance[0].reason if advance.size() else "nothing"))
	remove_spawned(distant)

	var just_right: Unit = spawn_brute(10.0)
	check("proposes nothing inside the tolerance band, leaving the baseline attack",
		behavior.propose(archer).is_empty())
	free_spawned()


## Area abilities were unreachable by any AI before this behavior — the
## baseline enumeration covers unit-targeted abilities only, so a caster
## holding a fireball simply never cast it.
func _area_target() -> void:
	var behavior := AreaTargetBehavior.new()
	behavior.ability = load("res://data/abilities/explosive_fireball.tres")
	behavior.min_targets = 2

	var caster: Unit = spawn_unit(&"enemy", 10, 12, 20, [behavior.ability], Vector3.ZERO)
	var a: Unit = spawn_brute(20.0)
	var b: Unit = spawn_brute(21.0)
	var c: Unit = spawn_brute(20.0, 1.0)
	var clustered: Array[AiPlan] = behavior.propose(caster)
	check("proposes a blast centred on a cluster",
		clustered.size() > 0 and clustered[0].target is Vector3,
		"%d proposals" % clustered.size())

	remove_spawned(b)
	remove_spawned(c)
	check("declines on a lone target", behavior.propose(caster).is_empty())
	free_spawned()


func _focus_fire() -> void:
	var behavior := FocusFireBehavior.new()
	var unit: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3.ZERO)
	var ally: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3(9.0, 0.0, 0.0))
	var engaged: Unit = spawn_brute(10.0)
	var isolated: Unit = spawn_brute(30.0)

	var targets: Array = []
	for plan in behavior.propose(unit):
		targets.append(plan.target)
	check("proposes the target an ally is already engaging",
		targets.has(engaged) and not targets.has(isolated))
	free_spawned()


func _support_ally() -> void:
	var behavior := SupportAllyBehavior.new()
	var heals: Array[Ability] = [load("res://data/abilities/heal.tres")]
	var cures: Array[Ability] = [load("res://data/abilities/cure.tres")]
	behavior.heal_abilities = heals
	behavior.cure_abilities = cures

	var healer: Unit = spawn_unit(&"enemy", 10, 12, 20, [heals[0], cures[0]], Vector3.ZERO)
	var ally: Unit = spawn_unit(&"enemy", 10, 12, 20, [melee()], Vector3(2.0, 0.0, 0.0))

	var offered_to_ally: int = 0
	for plan in behavior.propose(healer):
		if plan.target == ally:
			offered_to_ally += 1
	check("offers nothing to a healthy, unstatused ally", offered_to_ally == 0,
		"%d offers" % offered_to_ally)

	ally.current_hp = 5
	var heals_the_wounded: bool = false
	for plan in behavior.propose(healer):
		if plan.target == ally and plan.reason.begins_with("heal"):
			heals_the_wounded = true
	check("offers a heal once an ally is wounded", heals_the_wounded)
	free_spawned()


func _withdraw_after_attack() -> void:
	var behavior := WithdrawAfterAttackBehavior.new()
	var unit: Unit = spawn_unit(&"enemy", 12, 12, 20, [melee()], Vector3.ZERO)
	var foe: Unit = spawn_brute(1.5)

	check("silent while the attack is still available", behavior.propose(unit).is_empty())
	unit.has_attacked = true
	var after: Array[AiPlan] = behavior.propose(unit)
	check("falls back once the attack is spent",
		after.size() == 1 and after[0].pure_reposition
			and after[0].destination.distance_to(foe.global_position) > 1.5)
	free_spawned()


func _land_before_exhaustion() -> void:
	var behavior := LandBeforeExhaustionBehavior.new()
	behavior.turns_of_reserve = 2

	var flyer: Unit = spawn_demon("avian", Vector3(0.0, 8.0, 0.0), true)
	if not flyer.is_flying():
		check("SKIP guard: flying status applied", false, "is_flying() false")
		free_spawned()
		return

	flyer.current_fp = flyer.maximum_fp
	check("silent with FP to spare", behavior.propose(flyer).is_empty())

	flyer.current_fp = 1
	var offers_landing: bool = false
	var proposals: Array[AiPlan] = behavior.propose(flyer)
	for plan in proposals:
		if plan.reason.begins_with("land"):
			offers_landing = true
	check("offers a landing when the FP is nearly gone", offers_landing,
		"%d proposals" % proposals.size())
	free_spawned()
