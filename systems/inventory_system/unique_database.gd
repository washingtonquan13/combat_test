class_name UniqueDatabase
extends RefCounted
## Every UniqueItem under res://data/uniques/*.tres — same static
## scan-and-cache as ItemDatabase (see that file).

const UNIQUES_DIR: String = "res://data/uniques/"

static var _catalog: ResourceCatalog


static func get_all() -> Array[UniqueItem]:
	var result: Array[UniqueItem] = []
	for resource in _get_catalog().all():
		result.append(resource as UniqueItem)
	return result


static func find(id: StringName) -> UniqueItem:
	return _get_catalog().find(id) as UniqueItem


static func _get_catalog() -> ResourceCatalog:
	if not _catalog:
		var extract_id := func(resource: Resource) -> Variant:
			var unique := resource as UniqueItem
			return unique.id if unique else null
		_catalog = ResourceCatalog.new(UNIQUES_DIR, false, extract_id, false, false, false)
	return _catalog
