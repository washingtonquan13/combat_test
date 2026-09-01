class_name DemonDatabase
extends RefCounted
## Resolves a unit definition id to its UnitDefinition resource by
## scanning res://data/units/demons/* once and caching the result — same
## "index a data folder once, cache by id" idiom as SkillDatabase (see
## that file's own header), reused here for the same reason: a
## UnitDefinition is one self-contained .tres, never split across linked
## files the way a DialogueNode tree is, so a flat, non-recursive scan
## matches the shape of the data.
##
## Indexes UnitDefinition TEMPLATES only — never OwnedDemon instances,
## which are runtime roster state (see DemonRoster), not authored files.
##
## Stateless from the outside — static, no instances, not an autoload —
## matching SkillDatabase rather than FlagManager/DemonRoster: nothing
## here needs to persist across scenes, just a cache that outlives one
## call.

const DEMONS_DIR: String = "res://data/units/demons/"

static var _by_id: Dictionary = {}


## Null if no definition with this id has ever been saved under DEMONS_DIR.
static func find(id: String) -> UnitDefinition:
	if _by_id.is_empty():
		_load_all()
	return _by_id.get(id)


## Every indexed definition, in no particular guaranteed order — the
## compendium panel is the caller that needs "all of them," to build
## its unowned/undiscovered listing.
static func get_all() -> Array[UnitDefinition]:
	if _by_id.is_empty():
		_load_all()
	var result: Array[UnitDefinition] = []
	for species in _by_id.values():
		result.append(species)
	return result


## Every definition belonging to order, in no particular guaranteed
## order — FusionCalculator's own candidate pool for a fusion result.
static func members_of_order(order: StringName) -> Array[UnitDefinition]:
	var result: Array[UnitDefinition] = []
	for species in get_all():
		if species.order == order:
			result.append(species)
	return result


## Forces a re-scan — same escape hatch as SkillDatabase.refresh(), for
## a dev/modding workflow that adds or edits a demon .tres at runtime.
## Ordinary play never calls this.
static func refresh() -> void:
	_by_id.clear()
	_load_all()


static func _load_all() -> void:
	for file_name in DirAccess.get_files_at(DEMONS_DIR):
		if not file_name.ends_with(".tres"):
			continue
		var species := load(DEMONS_DIR + file_name) as UnitDefinition
		if species:
			_by_id[species.id] = species
