class_name AdvantageDatabase
extends RefCounted
## Finds an Advantage by id by scanning res://data/advantages/ once. Saves
## store the id, so a file can move without breaking one.

const ADVANTAGES_DIR: String = "res://data/advantages/"

static var _catalog: ResourceCatalog


## Null if no file declares this id.
static func find(id: StringName) -> Advantage:
	return _get_catalog().find(id) as Advantage


static func get_all() -> Array[Advantage]:
	var result: Array[Advantage] = []
	for resource in _get_catalog().all():
		result.append(resource as Advantage)
	return result


## Forces a re-scan, for a file added while the game runs.
static func refresh() -> void:
	_get_catalog().refresh()
	_report_duplicates()


static func _get_catalog() -> ResourceCatalog:
	if not _catalog:
		var extract_id := func(resource: Resource) -> Variant:
			var advantage := resource as Advantage
			return advantage.id if advantage and advantage.id != &"" else null
		_catalog = ResourceCatalog.new(ADVANTAGES_DIR, false, extract_id, true, false, true)
		_report_duplicates()
	return _catalog


## Two files claiming one id is an authoring mistake to report, not a tie
## to break quietly.
static func _report_duplicates() -> void:
	var seen: Dictionary = {}
	for resource in _catalog.all():
		var advantage := resource as Advantage
		if seen.has(advantage.id):
			push_error("Advantages: two files declare id '%s' (%s and %s); the first is used." % [advantage.id, seen[advantage.id], advantage.resource_path])
		else:
			seen[advantage.id] = advantage.resource_path
