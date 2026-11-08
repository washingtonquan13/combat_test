extends AiTestCase
## Progression: XP shared by the party levels every member, the points
## carry in a save, and the level-up screen writes what it bought onto
## the live Unit. Progression and PartyManager are put back afterwards.


func wants_world() -> bool:
	return true


func run() -> void:
	var saved_progression: Dictionary = Progression.save_state()
	var saved_party: Dictionary = PartyManager.save_state()
	Progression.load_state({})

	var hero: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3.ZERO)
	PartyManager.add_member(hero)
	var table: ProgressionTable = Progression.TABLE

	Progression.award_xp(table.xp_for(2), "test")
	var points: Dictionary = Progression.unspent(hero)
	check("enough XP reaches level 2", Progression.level == 2, "level %d" % Progression.level)
	check("the member gets a level's points",
		points[Progression.ATTRIBUTES] == table.attribute_points
		and points[Progression.ABILITIES] == table.ability_picks, str(points))
	check("spend refuses more than is there", not Progression.spend(hero, 99, 0, 0))

	var round_trip: Dictionary = Progression.save_state()
	Progression.load_state({})
	Progression.load_state(round_trip)
	check("a save keeps XP, level and points",
		Progression.level == 2 and Progression.unspent(hero) == points, str(Progression.unspent(hero)))

	var screen: Node = load("res://systems/character_creation_system/character_creation.tscn").instantiate()
	screen.visible = false  # as MainRoot places it
	add_child(screen)
	var st: float = hero.get_base_stat(StatIds.ST)
	var hp_max: float = hero.get_stat(StatIds.HP)
	var hp_before: float = hero.get_pool(StatIds.HP)
	var why: String = screen.open_level_up(hero)
	check("the level-up screen opens", why.is_empty(), why)
	var learnable: Ability = null
	for ability in AbilityDatabase.get_all():
		if table.is_learnable(ability) and not screen._knows_ability(hero, ability):
			learnable = ability
			break
	screen._attribute_values[String(StatIds.ST)] = int(st) + 1
	screen._picked_abilities.append(learnable)
	screen._confirm_level_up()

	check("ST was raised", hero.get_base_stat(StatIds.ST) == st + 1, str(hero.get_base_stat(StatIds.ST)))
	check("the HP the higher max adds is there to use",
		hero.get_pool(StatIds.HP) - hp_before == hero.get_stat(StatIds.HP) - hp_max,
		"hp %s -> %s, max %s -> %s" % [hp_before, hero.get_pool(StatIds.HP), hp_max, hero.get_stat(StatIds.HP)])
	check("the picked ability was learned", learnable != null and screen._knows_ability(hero, learnable))
	check("the spent points are gone, the rest carry over",
		Progression.unspent(hero)[Progression.ABILITIES] == table.ability_picks - 1
		and Progression.unspent(hero)[Progression.SKILLS] == table.skill_points)

	screen.queue_free()
	PartyManager.remove_member(hero)
	free_spawned()
	PartyManager.load_state(saved_party)
	Progression.load_state(saved_progression)
