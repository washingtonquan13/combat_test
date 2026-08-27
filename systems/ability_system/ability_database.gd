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


static func _load_all() -> void:
	for file_name in DirAccess.get_files_at(ABILITIES_DIR):
		if not file_name.ends_with(".tres"):
			continue
		var ability := load(ABILITIES_DIR + file_name) as Ability
		if ability:
			_all.append(ability)
