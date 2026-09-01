extends AiTestCase
## A definition can describe a whole character, not just a statline.
##
## Written to unblock deleting the four companions hand-placed in
## test_arena.tscn. They could not go while UnitDefinition had no field for
## the things still on those nodes — alignment, tendency, move_speed,
## selected_color, dialogue_options and three SkillInstance children.
## Deleting them would have quietly dropped a chaotic-good spellcaster's
## alignment, her skill investment, and an NPC conversation hook.
##
## Two properties, and the first is the one that could break the game
## everywhere at once:
##
## 1. A DEFINITION THAT SAYS NOTHING CHANGES NOTHING. Every new field
##    defaults to Unit's own default, so all 32 existing definitions —
##    which mention none of them — leave their units exactly as they were.
##    hover_color was left out for precisely this reason: unit.tscn
##    overrides it scene-wide, so any definition default would have had to
##    duplicate that value or re-tint every unit in the game.
##
## 2. A DEFINITION THAT SPEAKS IS OBEYED, including for skills — which
##    cannot ride the cascade, because a SkillInstance is a node that
##    UnitSkills reparents and UnitSkills does not exist until _ready.

const SKILL := "res://data/skills/acrobatics.tres"

var _units: Array[Unit] = []


func run() -> void:
	await _a_silent_definition_changes_nothing()
	await _a_definition_that_speaks_is_obeyed()
	await _the_scene_still_wins_while_it_has_an_opinion()
	_cleanup()


func _a_silent_definition_changes_nothing() -> void:
	var unit: Unit = _spawn(UnitDefinition.new())
	await get_tree().process_frame

	check("a definition that mentions nothing leaves alignment alone",
		unit.alignment == 0 and unit.tendency == 0,
		"alignment %d, tendency %d" % [unit.alignment, unit.tendency])
	check("and move speed",
		is_equal_approx(unit.move_speed, 4.0), "%.2f" % unit.move_speed)
	check("and the selection colour",
		unit.selected_color.is_equal_approx(Color(1, 0.85, 0.2, 0.9)),
		str(unit.selected_color))
	check("and gives it no skills it did not ask for",
		unit.get_skills().is_empty(), "%d skill(s)" % unit.get_skills().size())


func _a_definition_that_speaks_is_obeyed() -> void:
	var skill: Skill = load(SKILL)
	if skill == null:
		check("SETUP: a real skill to train", false, SKILL)
		return

	var record := PartySkillRecord.new()
	record.skill = skill
	record.levels_purchased = 7

	var definition := UnitDefinition.new()
	definition.alignment = -100
	definition.tendency = 100
	definition.move_speed = 5.0
	definition.selected_color = Color(0.156863, 1, 1, 0.627451)
	var trained: Array[PartySkillRecord] = [record]
	definition.skills = trained

	var unit: Unit = _spawn(definition)
	await get_tree().process_frame

	check("a declared alignment reaches the unit",
		unit.alignment == -100 and unit.tendency == 100,
		"alignment %d, tendency %d" % [unit.alignment, unit.tendency])
	check("and a declared move speed",
		is_equal_approx(unit.move_speed, 5.0), "%.2f" % unit.move_speed)
	check("and a declared selection colour",
		unit.selected_color.is_equal_approx(Color(0.156863, 1, 1, 0.627451)),
		str(unit.selected_color))

	var skills: Array[SkillInstance] = unit.get_skills()
	check("and a declared skill is really trained on it",
		skills.size() == 1 and skills[0].skill_data == skill,
		"%d skill(s)" % skills.size())
	check("at the level the definition purchased, not a default",
		skills.size() == 1 and skills[0].levels_purchased == 7,
		"level %d" % (skills[0].levels_purchased if skills.size() == 1 else -1))


## The migration guard. While the four companions are still hand-placed,
## a scene can author SkillInstance children directly — and a definition
## listing the same ones must not hand out a second copy of each.
func _the_scene_still_wins_while_it_has_an_opinion() -> void:
	var skill: Skill = load(SKILL)
	var record := PartySkillRecord.new()
	record.skill = skill
	record.levels_purchased = 7

	var definition := UnitDefinition.new()
	definition.model_scene = load("res://scenes/character_models/placeholder_model.tscn")
	var trained: Array[PartySkillRecord] = [record]
	definition.skills = trained

	var unit: Unit = load("res://unit.tscn").instantiate()
	unit.definition = definition

	# Authored by hand, before the unit is ever in the tree — which is what
	# a scene-placed SkillInstance amounts to.
	var authored := SkillInstance.new()
	authored.skill_data = skill
	authored.levels_purchased = 2
	unit.get_node("Skills").add_child(authored)

	_root.add_child(unit)
	_units.append(unit)
	await get_tree().process_frame

	var skills: Array[SkillInstance] = unit.get_skills()
	check("a unit that already has skills is not given duplicates",
		skills.size() == 1, "%d skill(s) — the definition doubled up" % skills.size())
	check("and keeps the level the scene authored, not the definition's",
		skills.size() == 1 and skills[0].levels_purchased == 2,
		"level %d" % (skills[0].levels_purchased if skills.size() == 1 else -1))


func _spawn(definition: UnitDefinition) -> Unit:
	definition.model_scene = load("res://scenes/character_models/placeholder_model.tscn")
	var unit: Unit = load("res://unit.tscn").instantiate()
	unit.definition = definition
	_root.add_child(unit)
	_units.append(unit)
	return unit


func _cleanup() -> void:
	for unit in _units:
		if is_instance_valid(unit):
			if unit.is_in_group("units"):
				unit.remove_from_group("units")
			if unit.get_parent():
				unit.get_parent().remove_child(unit)
			unit.queue_free()
	_units.clear()
