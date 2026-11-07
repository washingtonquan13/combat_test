extends "res://tools/size_demo.gd"
## Recorded showcase of Enlarge/Reduce Person - NOT a test. The hero
## enlarges itself (twice: no stacking), reduces an ally, then reduces a
## hostile dragon. Prints SM, ST, HP and the worn scale after each.

const Enlarge: Ability = preload("res://data/abilities/enlarge_person.tres")
const Reduce: Ability = preload("res://data/abilities/reduce_person.tres")


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	var camera: CRPGCamera = get_tree().root.find_children("*", "CRPGCamera", true, false)[0]
	var ally: Unit = null
	var i: int = 0
	for member: Unit in PartyManager.members:
		if member == _hero:
			continue
		if ally == null:
			ally = member
			member.global_position = _spot(-2.0, 2.0)
			member.snap_face_direction(_hero.visual_forward())
		else:
			member.global_position = _spot(9.0 + i * 1.5, -9.0)
			i += 1
	SelectionManager.select(_hero)
	AbilityManager.armed_ability = Enlarge
	print("CLICK self -> %s" % [_hero.click_ability_for(_hero).ability_name if _hero.click_ability_for(_hero) else "none"])
	AbilityManager.armed_ability = null
	_frame(_spot(-1.0, 1.0), 6.0)
	await _wait(1.5)
	_report("start", [_hero, ally])

	_hero.use_ability(Enlarge, _hero)
	await _wait(3.0)
	_report("enlarged self", [_hero])
	_hero.use_ability(Enlarge, _hero)
	await _wait(2.5)
	_report("enlarged self again", [_hero])
	if OS.get_environment("SIZE_GROUP_ONLY") != "":
		for ability: Ability in [Reduce, Reduce, Reduce, Enlarge, Enlarge, Enlarge]:
			var result: Dictionary = ability.effects[0].apply(_hero, _hero, ability, false)
			await _wait(1.0)
			_report("%s -> %s" % [ability.ability_name, result], [_hero])
		get_tree().quit()
		return

	_hero.use_ability(Reduce, ally)
	await _wait(3.0)
	_report("reduced ally", [ally])

	var dragon: Unit = _spawn("res://data/units/demons/dragon.tres", _spot(-4.0, -0.5))
	dragon.faction = &"enemy"
	# HT 18 resists Reduce nearly every time; lowered so the shrink shows.
	dragon.set_base_stat(StatIds.HT, 6)
	_frame(_spot(-2.5, 0.5), 11.0)
	_report("dragon", [dragon])
	var result: Dictionary = await _hero.use_ability(Reduce, dragon)
	_frame(dragon.global_position.lerp(_hero.global_position, 0.4), 9.0)
	print("CAST dragon hit %s effects %s" % [result.hit, result.effects])
	await _wait(3.0)
	_report("reduced dragon", [dragon])
	_frame(dragon.global_position.lerp(_hero.global_position, 0.4), 9.0)
	await _wait(2.0)
	get_tree().quit()


func _report(label: String, units: Array) -> void:
	for unit: Unit in units:
		print("SIZE %s | %s SM %d ST %d HP %d/%d scale %.2f radius %.2f statuses %s" % [label, unit.display_name,
			unit.get_stat(StatIds.SM), unit.get_stat(StatIds.ST), unit.get_pool(StatIds.HP),
			unit.get_stat(StatIds.HP), unit.worn_size, unit.radius,
			unit.active_statuses().map(func(s): return s.status_name)])
