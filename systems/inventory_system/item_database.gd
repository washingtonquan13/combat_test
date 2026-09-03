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
##
## The scan-and-cache itself is ResourceCatalog (see that file's header
## for the full behaviour matrix); this file only supplies its directory,
## its id field, and the non-recursive/last-wins/no-dedupe shape that
## matches the original hand-written loader exactly.

const ITEMS_DIR: String = "res://data/items/"

static var _catalog: ResourceCatalog


static func get_all() -> Array[ItemDefinition]:
	var result: Array[ItemDefinition] = []
	for resource in _get_catalog().all():
		result.append(resource as ItemDefinition)
	return result


## Null if no ItemDefinition with this id has ever been saved under
## ITEMS_DIR.
static func find(id: StringName) -> ItemDefinition:
	return _get_catalog().find(id) as ItemDefinition


## Forces a re-scan — same escape hatch SkillDatabase/DemonDatabase
## expose, for a dev/modding workflow that adds or edits an item .tres
## at runtime. Ordinary play never calls this.
static func refresh() -> void:
	_get_catalog().refresh()


static func _get_catalog() -> ResourceCatalog:
	if not _catalog:
		var extract_id := func(resource: Resource) -> Variant:
			var definition := resource as ItemDefinition
			return definition.id if definition else null
		_catalog = ResourceCatalog.new(ITEMS_DIR, false, extract_id, false, false, false)
	return _catalog
