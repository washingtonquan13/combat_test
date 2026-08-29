class_name SpawnableUnitDatabase
extends RefCounted
## Every UnitDefinition that could plausibly be placed via the debug
## spawn tool — res://data/demons/*.tres AND res://data/units/*.tres
## combined into one flat list. Deliberately NOT merged into
## DemonDatabase (see that file) and deliberately NOT id-keyed the way
## DemonDatabase is — nothing here needs single-id lookup yet (the spawn
## panel only ever wants "all of them"), and an id-keyed cache would
## silently let a units/ definition and a demons/ definition sharing an
## id overwrite each other; a flat array can't have that failure mode.
##
## Stateless from the outside — static, no instances, not an autoload —
## same reasoning as DemonDatabase.

const DEMONS_DIR: String = "res://data/demons/"
const UNITS_DIR: String = "res://data/units/"

static var _all: Array[UnitDefinition] = []


static func get_all() -> Array[UnitDefinition]:
	if _all.is_empty():
		_load_all()
	return _all


## Null if no definition with this id exists in either directory. A
## linear scan, deliberately not a cached id->definition dict — see this
## file's own header on why a flat array is kept instead of one: an id
## collision between demons/ and units/ is a pre-existing authoring risk
## either way, and this returns whichever this array happens to hold
## first rather than letting one silently overwrite the other in a
## cache. Needed for save/load: PartyMemberData.definition is saved as
## an id (see SaveManager), and a saved leader/companion can come from
## EITHER directory — DemonDatabase.find() alone can't resolve a
## units/-sourced definition.
static func find(id: String) -> UnitDefinition:
	if _all.is_empty():
		_load_all()
	for definition in _all:
		if definition.id == id:
			return definition
	return null


static func refresh() -> void:
	_all.clear()
	_load_all()


static func _load_all() -> void:
	for dir in [DEMONS_DIR, UNITS_DIR]:
		for file_name in DirAccess.get_files_at(dir):
			if not file_name.ends_with(".tres"):
				continue
			var definition := load(dir + file_name) as UnitDefinition
			if definition:
				_all.append(definition)
