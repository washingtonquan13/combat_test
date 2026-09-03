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
##
## The scan-and-cache itself is ResourceCatalog (see that file's header
## for the full behaviour matrix); this file only supplies its directory,
## its id field (skill_name, since Skill is keyed by name), and the
## non-recursive/last-wins/dedupe shape that matches the original
## hand-written loader exactly (get_all() was always built from a dict's
## values, so a duplicate name collapsed to one entry).

const SKILLS_DIR: String = "res://data/skills/"

static var _catalog: ResourceCatalog


## Null if no skill with this name has ever been saved under SKILLS_DIR.
static func find(skill_name: String) -> Skill:
	return _get_catalog().find(skill_name) as Skill


## Every skill in the game — the character-creation skill list's own
## source, same "index once, cache by id, also expose get_all() for a
## picker UI" idiom MusicTrackDatabase/DemonDatabase already use.
static func get_all() -> Array[Skill]:
	var result: Array[Skill] = []
	for resource in _get_catalog().all():
		result.append(resource as Skill)
	return result


## Forces a re-scan — call after adding/removing/renaming a skill .tres
## at runtime (e.g. a modding/dev workflow); ordinary play never needs
## this, since the roster of skill FILES doesn't change mid-session.
static func refresh() -> void:
	_get_catalog().refresh()


static func _get_catalog() -> ResourceCatalog:
	if not _catalog:
		var extract_id := func(resource: Resource) -> Variant:
			var skill := resource as Skill
			return skill.skill_name if skill else null
		_catalog = ResourceCatalog.new(SKILLS_DIR, false, extract_id, false, true, false)
	return _catalog
