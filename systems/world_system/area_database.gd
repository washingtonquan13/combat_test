class_name AreaDatabase
extends RefCounted
## Every AreaDefinition under res://data/areas/*.tres — same flat-
## directory-scan idiom as MusicTrackDatabase/SkillDatabase/DemonDatabase/
## SpawnableUnitDatabase. Stateless from the outside — static, no
## instances, not an autoload.
##
## This eager scan is the whole reason doors/exits reference an area by
## id rather than holding an AreaDefinition directly (see that field's
## own doc comment on AreaDefinition) — get_all()/find() being the ONLY
## code path that ever touches world_scene keeps the eager-PackedScene
## cost confined to exactly one file.

const AREAS_DIR: String = "res://data/areas/"

static var _all: Array[AreaDefinition] = []
static var _by_id: Dictionary = {}


static func get_all() -> Array[AreaDefinition]:
	if _all.is_empty():
		_load_all()
	return _all


## Null if no area with this id has ever been saved under AREAS_DIR.
static func find(id: StringName) -> AreaDefinition:
	if _all.is_empty():
		_load_all()
	return _by_id.get(id)


static func _load_all() -> void:
	for file_name in DirAccess.get_files_at(AREAS_DIR):
		if not file_name.ends_with(".tres"):
			continue
		var area := load(AREAS_DIR + file_name) as AreaDefinition
		if area:
			_all.append(area)
			_by_id[area.id] = area
