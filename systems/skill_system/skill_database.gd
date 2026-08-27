class_name SkillDatabase
extends RefCounted
## Resolves a skill name to its Skill resource by scanning
## res://data/skills/* once and caching the result — the actual mechanism
## behind "theoretically infinite skills, just drop a new .tres in the
## folder" (see Skill's own header). Replaces the original design's
## per-call ResourceLoader.load() against a file path reconstructed from
## a formatted display name — that reload happened on EVERY lookup, even
## for a skill the caller already had a live reference to (see
## SkillCalculator.get_skill_level, which now only consults this for a
## skill a unit hasn't actually learned).
##
## Stateless from the outside — static, no instances — but the cache
## itself has to live somewhere, hence `static var` rather than a plain
## const table.

const SKILLS_DIR: String = "res://data/skills/"

static var _by_name: Dictionary = {}


## Null if no skill with this name has ever been saved under SKILLS_DIR.
static func find(skill_name: String) -> Skill:
	if _by_name.is_empty():
		_load_all()
	return _by_name.get(skill_name)


## Every skill in the game — the character-creation skill list's own
## source, same "index once, cache by id, also expose get_all() for a
## picker UI" idiom MusicTrackDatabase/DemonDatabase already use.
static func get_all() -> Array[Skill]:
	if _by_name.is_empty():
		_load_all()
	var result: Array[Skill] = []
	for skill in _by_name.values():
		result.append(skill)
	return result


## Forces a re-scan — call after adding/removing/renaming a skill .tres
## at runtime (e.g. a modding/dev workflow); ordinary play never needs
## this, since the roster of skill FILES doesn't change mid-session.
static func refresh() -> void:
	_by_name.clear()
	_load_all()


static func _load_all() -> void:
	for file_name in DirAccess.get_files_at(SKILLS_DIR):
		if not file_name.ends_with(".tres"):
			continue
		var skill := load(SKILLS_DIR + file_name) as Skill
		if skill:
			_by_name[skill.skill_name] = skill
