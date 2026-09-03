class_name ResourceCatalog
extends RefCounted
## Shared engine behind AbilityDatabase/AreaDatabase/DemonDatabase/
## SpawnableUnitDatabase/ItemDatabase/MusicTrackDatabase/QuestDatabase/
## SkillDatabase — all eight were the same "scan a data folder once, cache
## the results, expose all()/find()" idiom copy-pasted with a different
## directory and a different id field each time. Each database keeps its
## own file (class_name, static wrapper functions, its own DIR const) so
## every existing caller and every existing public signature is
## untouched; only the scan-and-cache guts move here, behind one
## `static var _catalog: ResourceCatalog` per database.
##
## Preserved per-database behaviour, each now a constructor parameter
## rather than a hardcoded assumption, because the eight originals
## genuinely disagreed with each other:
##
## - recursive: only SpawnableUnitDatabase walks subfolders (demons/,
##   companions/, npcs/, summons/, ... under data/units/ at any depth).
##   The other seven do one flat DirAccess.get_files_at() pass over their
##   own directory, same as before.
## - handle_remap: only SpawnableUnitDatabase strips a ".tres.remap"
##   suffix before the ".tres" check, for a save/load id lookup that has
##   to keep resolving in an exported build. The other seven never did
##   this, so an exported build's .remap files silently fail their
##   ends_with(".tres") check exactly as they did before this refactor —
##   not fixed here, since that's a behaviour change beyond "add
##   refresh()".
## - find_first_wins: AbilityDatabase and SpawnableUnitDatabase never
##   built an id->resource dict; find() was a linear scan of the load-
##   order array returning the FIRST match, and both files say why in
##   their own headers (SpawnableUnitDatabase in particular: two
##   definitions sharing an id must not let one silently overwrite the
##   other). The other six built a dict by unconditionally assigning on
##   every load, so a later duplicate id wins. This flag reproduces both:
##   true only inserts a key the first time it's seen (first match wins,
##   matching the old linear scan exactly); false always overwrites
##   (matching the old dict assignment exactly). find() itself is always
##   an O(1) dict lookup either way — same return value as the original
##   per-database algorithm, just not re-scanning the array every call
##   for the two that used to.
## - dedupe_all: DemonDatabase/QuestDatabase/SkillDatabase never kept a
##   load-order array at all — get_all() was built fresh from
##   _by_id.values() every call, which is why a duplicate id collapses to
##   one entry there (Dictionary preserves each key's first insertion
##   position but the last-assigned value, matching find_first_wins=false
##   above). The other five return the load-order array directly, so a
##   duplicate id shows up twice in get_all() even though find() only
##   ever resolves to one of them. true reproduces the dict.values()
##   dedupe; false reproduces the raw-array pass-through.
##
## Not a parameter because no original loader did it: none of the eight
## sorted their results — get_all() order is whatever DirAccess (and, for
## the recursive case, the pending-directory stack) happens to hand back.
##
## The id extractor Callable takes the freshly `load()`ed Resource and
## returns its id (whatever field the caller's find() is keyed on —
## ability_name, skill_name, or an id property of varying type: String
## for UnitDefinition/MusicTrack/Quest, StringName for AreaDefinition/
## ItemDefinition) or "" / null to mean "skip this file" — the same job
## the original `load(path) as ConcreteType` + `if concrete:` guard did,
## just moved into the caller since this file has no compile-time
## knowledge of the eight concrete resource types.

var _directory: String
var _recursive: bool
var _handle_remap: bool
var _find_first_wins: bool
var _dedupe_all: bool
var _id_extractor: Callable

var _all: Array[Resource] = []
var _by_id: Dictionary = {}


func _init(directory: String, recursive: bool, id_extractor: Callable,
		find_first_wins: bool = false, dedupe_all: bool = false,
		handle_remap: bool = false) -> void:
	_directory = directory
	_recursive = recursive
	_id_extractor = id_extractor
	_find_first_wins = find_first_wins
	_dedupe_all = dedupe_all
	_handle_remap = handle_remap


## Every loaded resource, in load order. Deduped by id when dedupe_all
## was set (matching the DemonDatabase/QuestDatabase/SkillDatabase
## originals); otherwise the raw load-order array, duplicates included
## (matching the other five originals) — same object every call, callers
## must not mutate it.
func all() -> Array[Resource]:
	_ensure_loaded()
	if not _dedupe_all:
		return _all
	var result: Array[Resource] = []
	for resource in _by_id.values():
		result.append(resource)
	return result


## Null if no resource with this id was loaded. O(1) dict lookup; see
## find_first_wins above for which duplicate wins on an id collision.
func find(id) -> Resource:
	_ensure_loaded()
	return _by_id.get(id)


## Forces a re-scan — same escape hatch DemonDatabase/QuestDatabase/
## SkillDatabase/SpawnableUnitDatabase already exposed as refresh(), now
## on all eight.
func refresh() -> void:
	_all.clear()
	_by_id.clear()
	_ensure_loaded()


## Re-attempts the scan on every call while the directory has produced
## nothing yet, same as every original (`if _all.is_empty(): _load_all()`
## / `if _by_id.is_empty(): _load_all()`) — a data folder that starts out
## empty and gains a file later without a refresh() call still resolves,
## which is a pre-existing quirk of the originals, not a new one.
func _ensure_loaded() -> void:
	if _all.is_empty():
		_load_all()


func _load_all() -> void:
	if _recursive:
		var pending: Array[String] = [_directory]
		while not pending.is_empty():
			var dir: String = pending.pop_back()
			for sub in DirAccess.get_directories_at(dir):
				pending.append(dir + sub + "/")
			_load_files_in(dir)
	else:
		_load_files_in(_directory)


func _load_files_in(dir: String) -> void:
	for file_name in DirAccess.get_files_at(dir):
		var trimmed_name := file_name
		if _handle_remap and trimmed_name.ends_with(".tres.remap"):
			trimmed_name = trimmed_name.trim_suffix(".remap")
		if not trimmed_name.ends_with(".tres"):
			continue
		var resource := load(dir + trimmed_name) as Resource
		if not resource:
			continue
		var id = _id_extractor.call(resource)
		if id == null:
			continue
		_all.append(resource)
		# A blank id stays in all() so a misauthored file shows up visibly
		# wrong instead of vanishing; it just cannot be found by id.
		if id == "":
			continue
		if _find_first_wins:
			if not _by_id.has(id):
				_by_id[id] = resource
		else:
			_by_id[id] = resource
