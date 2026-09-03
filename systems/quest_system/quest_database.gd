class_name QuestDatabase
extends RefCounted
## Resolves a quest id to its Quest resource by scanning
## res://data/quests/* once and caching the result — same "index a data
## folder once, cache by id" idiom as SkillDatabase (see that file's
## header), reused here rather than DialogueManager's recursive-
## directory version: a Quest is one self-contained .tres (id + title +
## stages), never split across several linked files the way a
## DialogueNode tree is, so a flat, non-recursive scan
## (DirAccess.get_files_at, exactly like SkillDatabase) matches the
## shape of the data — not the deeper walk DialogueManager needs for
## res://data/dialogue's per-NPC subfolders.
##
## Stateless from the outside — static, no instances, not an autoload —
## matching SkillDatabase/SkillCalculator rather than FlagManager/
## DialogueManager: nothing here needs to persist across scenes or live
## in the tree, just a cache that outlives one call.
##
## The scan-and-cache itself is ResourceCatalog (see that file's header
## for the full behaviour matrix); this file only supplies its directory,
## its id field, and the non-recursive/last-wins/dedupe shape that
## matches the original hand-written loader exactly (get_all() was
## always built from a dict's values, so a duplicate id collapsed to one
## entry).

const QUESTS_DIR: String = "res://data/quests/"

static var _catalog: ResourceCatalog


## Null if no quest with this id has ever been saved under QUESTS_DIR.
static func find(quest_id: String) -> Quest:
	return _get_catalog().find(quest_id) as Quest


## Every indexed quest, in no particular guaranteed order — the Journal
## panel is the one caller that needs "all of them," to build its list.
static func get_all() -> Array[Quest]:
	var result: Array[Quest] = []
	for resource in _get_catalog().all():
		result.append(resource as Quest)
	return result


## Forces a re-scan — same escape hatch as SkillDatabase.refresh(), for
## a dev/modding workflow that adds or edits a quest .tres at runtime.
## Ordinary play never calls this.
static func refresh() -> void:
	_get_catalog().refresh()


static func _get_catalog() -> ResourceCatalog:
	if not _catalog:
		var extract_id := func(resource: Resource) -> Variant:
			var quest := resource as Quest
			return quest.id if quest else null
		_catalog = ResourceCatalog.new(QUESTS_DIR, false, extract_id, false, true, false)
	return _catalog
