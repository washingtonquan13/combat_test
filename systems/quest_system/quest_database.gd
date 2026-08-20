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

const QUESTS_DIR: String = "res://data/quests/"

static var _by_id: Dictionary = {}


## Null if no quest with this id has ever been saved under QUESTS_DIR.
static func find(quest_id: String) -> Quest:
	if _by_id.is_empty():
		_load_all()
	return _by_id.get(quest_id)


## Every indexed quest, in no particular guaranteed order — the Journal
## panel is the one caller that needs "all of them," to build its list.
static func get_all() -> Array[Quest]:
	if _by_id.is_empty():
		_load_all()
	var result: Array[Quest] = []
	for quest in _by_id.values():
		result.append(quest)
	return result


## Forces a re-scan — same escape hatch as SkillDatabase.refresh(), for
## a dev/modding workflow that adds or edits a quest .tres at runtime.
## Ordinary play never calls this.
static func refresh() -> void:
	_by_id.clear()
	_load_all()


static func _load_all() -> void:
	for file_name in DirAccess.get_files_at(QUESTS_DIR):
		if not file_name.ends_with(".tres"):
			continue
		var quest := load(QUESTS_DIR + file_name) as Quest
		if quest:
			_by_id[quest.id] = quest
