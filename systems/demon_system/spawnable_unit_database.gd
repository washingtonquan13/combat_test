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


static func refresh() -> void:
	_all.clear()
	_load_all()


static func _load_all() -> void:
	for dir in [DEMONS_DIR, UNITS_DIR]:
		for file_name in DirAccess.get_files_at(dir):
			if not file_name.ends_with(".tres") or file_name == "fusion_chart.tres":
				continue
			var definition := load(dir + file_name) as UnitDefinition
			if definition:
				_all.append(definition)
