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
##
## The scan-and-cache itself is ResourceCatalog (see that file's header
## for the full behaviour matrix); this file only supplies its directory,
## its id field, and the non-recursive/last-wins/dedupe shape that
## matches the original hand-written loader exactly (get_all() was
## always built from a dict's values, so a duplicate id collapsed to one
## entry).

const DEMONS_DIR: String = "res://data/units/demons/"

static var _catalog: ResourceCatalog


## Null if no definition with this id has ever been saved under DEMONS_DIR.
static func find(id: String) -> UnitDefinition:
	return _get_catalog().find(id) as UnitDefinition


## Every indexed definition, in no particular guaranteed order — the
## compendium panel is the caller that needs "all of them," to build
## its unowned/undiscovered listing.
static func get_all() -> Array[UnitDefinition]:
	var result: Array[UnitDefinition] = []
	for resource in _get_catalog().all():
		result.append(resource as UnitDefinition)
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
	_get_catalog().refresh()


static func _get_catalog() -> ResourceCatalog:
	if not _catalog:
		var extract_id := func(resource: Resource) -> Variant:
			var species := resource as UnitDefinition
			return species.id if species else null
		_catalog = ResourceCatalog.new(DEMONS_DIR, false, extract_id, false, true, false)
	return _catalog
