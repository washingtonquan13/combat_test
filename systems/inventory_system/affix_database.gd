class_name AffixDatabase
extends RefCounted
## Every Affix under res://data/affixes/*.tres — same static scan-and-cache
## as ItemDatabase (see that file).

const AFFIXES_DIR: String = "res://data/affixes/"

static var _catalog: ResourceCatalog


static func get_all() -> Array[Affix]:
	var result: Array[Affix] = []
	for resource in _get_catalog().all():
		result.append(resource as Affix)
	return result


static func find(id: StringName) -> Affix:
	return _get_catalog().find(id) as Affix


static func _get_catalog() -> ResourceCatalog:
	if not _catalog:
		var extract_id := func(resource: Resource) -> Variant:
			var affix := resource as Affix
			return affix.id if affix else null
		_catalog = ResourceCatalog.new(AFFIXES_DIR, false, extract_id, false, false, false)
	return _catalog
