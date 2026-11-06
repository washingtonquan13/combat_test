extends AiTestCase
## Aim toggles (B398-399): the vitals take x3 from impaling and piercing
## only, the skull x4 behind 2 more DR; an attack the location doesn't
## take goes to the torso without the penalty. The toggles share a group,
## and the AI aims where it pays.


func wants_world() -> bool:
	return true


func run() -> void:
	var vitals_toggle: Ability = UnitCombat.AIM_TOGGLES[0]
	var head_toggle: Ability = UnitCombat.AIM_TOGGLES[1]
	var stab: Ability = _attack(DamageResolver.WoundType.IMPALING)
	var slash: Ability = _attack(DamageResolver.WoundType.CUTTING)
	var attacker: Unit = spawn_unit(&"player", 10, 18, 10, [stab, slash], Vector3.ZERO)
	var target: Unit = spawn_unit(&"enemy", 10, 10, 30, [melee()], Vector3(1.0, 0.0, 0.0))
	target.set_base_stat(StatIds.DR, 2)

	var vitals: HitLocation = vitals_toggle.hit_location
	var skull: HitLocation = head_toggle.hit_location
	var imp := DamageResolver.WoundType.IMPALING
	var to_vitals: int = DamageResolver.injury(7, target, imp, 1.0, false, false, vitals)
	var to_skull: int = DamageResolver.injury(7, target, imp, 1.0, false, false, skull)
	check("7 imp through DR 2: vitals x3 is 15, skull x4 behind DR 4 is 12",
		to_vitals == 15 and to_skull == 12, "vitals %d, skull %d" % [to_vitals, to_skull])

	var torso_number: int = attacker.to_hit_target(target, stab)
	attacker.set_aim(vitals_toggle)
	check("aiming at the vitals is -3 to hit", attacker.to_hit_target(target, stab) == torso_number - 3)
	check("a cutting blow aimed at the vitals hits the torso, no penalty",
		attacker.hit_location_for(slash) == null and attacker.to_hit_target(target, slash) == attacker.to_hit_target(target, stab) + 3)
	attacker.set_toggled(head_toggle, true)
	check("aim toggles are one group", attacker.is_toggled(head_toggle) and not attacker.is_toggled(vitals_toggle))
	attacker.set_aim(null)

	# DX 18 makes -3 cheap, and x3 beats x2.
	var plan := AiPlan.new()
	plan.ability = stab
	plan.target = target
	AiScorer._score_plan(attacker, plan)
	check("the AI aims a skilled stab at the vitals", plan.aim == vitals_toggle, "aim %s, %s" % [plan.aim, plan.reason])
	check("pricing aims leaves the unit's own aim alone", attacker.aim() == null)
	free_spawned()


func _attack(wound_type: DamageResolver.WoundType) -> Ability:
	var ability: Ability = melee().duplicate()
	var damage := DamageEffect.new()
	damage.dice_count = 2
	damage.wound_type = wound_type
	var effects: Array[AbilityEffect] = [damage]
	ability.effects = effects
	ability.requires_to_hit = true
	return ability
