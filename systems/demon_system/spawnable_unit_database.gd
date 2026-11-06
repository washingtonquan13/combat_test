class_name SpawnableUnitDatabase
extends RefCounted
## Every UnitDefinition in the project — everything under data/units/, at
## any depth — combined into one flat list.
##
## It began as "everything the debug spawn tool could plausibly place",
## which is still what get_all() is for. find() is a later and much less
## optional job: it is how a SAVE FILE turns a definition_id back into a
## definition, for party members (PartyManager._load_one) and for recruited
## demons (DemonRoster). A directory missing from the list below is not a
## gap in a debug menu — it is a saved character coming back with no
## definition, and therefore no BODY, because that is where a unit's model
## comes from.
##
## That is exactly what happened when companions and NPCs moved out of
## scenes and into data/: their definitions resolved to null on load and
## every one of them reloaded invisible. Deliberately NOT merged into
## DemonDatabase (see that file) and deliberately NOT id-keyed the way
## DemonDatabase is — nothing here needs single-id lookup yet (the spawn
## panel only ever wants "all of them"), and an id-keyed cache would
## silently let two definitions sharing an id overwrite each other; a flat
## array can't have that failure mode.
##
## Stateless from the outside — static, no instances, not an autoload —
## same reasoning as DemonDatabase.
##
## The scan-and-cache itself is ResourceCatalog (see that file's header
## for the full behaviour matrix); this file only supplies its directory,
## its id field, and the recursive/first-wins/remap-handling/no-dedupe
## shape that matches the original hand-written loader exactly — the
## first-wins id policy is what keeps the "two definitions sharing an id"
## failure mode described above out of find() (get_all() still surfaces
## both, unchanged, since dedupe is off).

## One root, walked recursively — demons/, companions/, npcs/, summons/ and
## whatever comes next. Deliberately NOT a list of directories: a hardcoded
## list is what caused every companion and NPC to reload invisible the day
## they moved out of scenes and into data/, because a directory missing
## from that list resolves its ids to null and a unit with no definition
## has no BODY. A subfolder added under here is covered by existing.
const ROOT_DIR: String = "res://data/units/"

static var _catalog: ResourceCatalog


static func get_all() -> Array[UnitDefinition]:
	var result: Array[UnitDefinition] = []
	for resource in _get_catalog().all():
		result.append(resource as UnitDefinition)
	return result


## Null if no definition with this id exists in either directory. See
## this file's own header on why a first-match, not a last-write-wins,
## resolution is kept for a duplicate id: an id collision between
## demons/ and units/ is a pre-existing authoring risk either way, and
## this returns whichever this array happens to hold first rather than
## letting one silently overwrite the other in a cache. Needed for
## save/load: PartyMemberData.definition is saved as an id (see
## SaveManager), and a saved leader/companion can come from EITHER
## directory — DemonDatabase.find() alone can't resolve a units/-sourced
## definition.
static func find(id: String) -> UnitDefinition:
	return _get_catalog().find(id) as UnitDefinition


static func refresh() -> void:
	_get_catalog().refresh()


static func _get_catalog() -> ResourceCatalog:
	if not _catalog:
		var extract_id := func(resource: Resource) -> Variant:
			var definition := resource as UnitDefinition
			return definition.id if definition else null
		_catalog = ResourceCatalog.new(ROOT_DIR, true, extract_id, true, false, true)
	return _catalog
