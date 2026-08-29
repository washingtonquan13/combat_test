class_name AbilityDatabase
extends RefCounted
## Resolves every Ability under res://data/abilities/* — same
## "theoretically infinite by scanning a folder" idiom
## SkillDatabase/DemonDatabase/MusicTrackDatabase already use, so a new
## ability dropped in that folder shows up in the debug grant list (see
## party_overview.gd's AbilitiesColumn) with no code change.
##
## Stateless from the outside — static, no instances — same reasoning
## SkillDatabase/DemonDatabase already give for themselves.

const ABILITIES_DIR: String = "res://data/abilities/"

static var _all: Array[Ability] = []


static func get_all() -> Array[Ability]:
	if _all.is_empty():
		_load_all()
	return _all


## Null if no ability with this name exists. Keyed on ability_name, not a
## dedicated id field — Ability has none, and ability_name is already the
## unique-enough key SkillDatabase.find(skill_name) uses for the same
## reason on Skill. Needed for save/load: PartyMemberData.abilities/
## custom_slots are saved as name arrays (see SaveManager), same
## resource-by-id convention every other saved reference uses.
static func find(ability_name: String) -> Ability:
	for ability in get_all():
		if ability.ability_name == ability_name:
			return ability
	return null


static func _load_all() -> void:
	for file_name in DirAccess.get_files_at(ABILITIES_DIR):
		if not file_name.ends_with(".tres"):
			continue
		var ability := load(ABILITIES_DIR + file_name) as Ability
		if ability:
			_all.append(ability)
