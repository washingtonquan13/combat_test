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
##
## The scan-and-cache itself is ResourceCatalog (see that file's header
## for the full behaviour matrix); this file only supplies its directory,
## its id field, and the non-recursive/last-wins/no-dedupe shape that
## matches the original hand-written loader exactly. AREAS_DIR stays a
## public const — area_validator.gd reports it directly in an issue
## message.

const AREAS_DIR: String = "res://data/areas/"

static var _catalog: ResourceCatalog


static func get_all() -> Array[AreaDefinition]:
	var result: Array[AreaDefinition] = []
	for resource in _get_catalog().all():
		result.append(resource as AreaDefinition)
	return result


## Null if no area with this id has ever been saved under AREAS_DIR.
static func find(id: StringName) -> AreaDefinition:
	return _get_catalog().find(id) as AreaDefinition


## Forces a re-scan — same escape hatch SkillDatabase/DemonDatabase
## expose, for a dev/modding workflow that adds or edits an area .tres
## at runtime. Ordinary play never calls this.
static func refresh() -> void:
	_get_catalog().refresh()


static func _get_catalog() -> ResourceCatalog:
	if not _catalog:
		var extract_id := func(resource: Resource) -> Variant:
			var area := resource as AreaDefinition
			return area.id if area else null
		_catalog = ResourceCatalog.new(AREAS_DIR, false, extract_id, false, false, false)
	return _catalog
