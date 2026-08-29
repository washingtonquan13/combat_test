class_name ItemDatabase
extends RefCounted
## Every ItemDefinition (GearItem or plain) under res://data/items/*.tres —
## same flat-directory-scan idiom as AreaDatabase/MusicTrackDatabase/
## SkillDatabase/DemonDatabase/SpawnableUnitDatabase. Stateless from the
## outside — static, no instances, not an autoload.
##
## This is what turns a saved ItemDefinition.id back into a real
## definition — see AreaState/StashComponent, which serialize items by
## id rather than holding a direct resource reference.

const ITEMS_DIR: String = "res://data/items/"

static var _all: Array[ItemDefinition] = []
static var _by_id: Dictionary = {}


static func get_all() -> Array[ItemDefinition]:
	if _all.is_empty():
		_load_all()
	return _all


## Null if no ItemDefinition with this id has ever been saved under
## ITEMS_DIR.
static func find(id: StringName) -> ItemDefinition:
	if _all.is_empty():
		_load_all()
	return _by_id.get(id)


static func _load_all() -> void:
	for file_name in DirAccess.get_files_at(ITEMS_DIR):
		if not file_name.ends_with(".tres"):
			continue
		var definition := load(ITEMS_DIR + file_name) as ItemDefinition
		if definition:
			_all.append(definition)
			_by_id[definition.id] = definition
