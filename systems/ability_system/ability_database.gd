class_name AbilityDatabase
extends RefCounted
## Resolves every Ability under res://data/abilities/* — same
## "theoretically infinite by scanning a folder" idiom
## SkillDatabase/DemonDatabase/MusicTrackDatabase already use, so a new
## ability dropped in that folder shows up in the debug grant list (see
## party_overview.gd's AbilitiesColumn) with no code change.
##
## Stateless from the outside — static, no instances — same reasoning
## SkillDatabase/DemonDatabase already give for themselves.
##
## The scan-and-cache itself is ResourceCatalog (see that file's header
## for the full behaviour matrix); this file only supplies its directory,
## its id field (ability_name, since Ability has no dedicated id), and
## the non-recursive/first-wins/no-dedupe shape that matches the original
## hand-written loader exactly.

const ABILITIES_DIR: String = "res://data/abilities/"

static var _catalog: ResourceCatalog


static func get_all() -> Array[Ability]:
	var result: Array[Ability] = []
	for resource in _get_catalog().all():
		result.append(resource as Ability)
	return result


## Null if no ability with this name exists. Keyed on ability_name, not a
## dedicated id field — Ability has none, and ability_name is already the
## unique-enough key SkillDatabase.find(skill_name) uses for the same
## reason on Skill. Needed for save/load: PartyMemberData.abilities/
## custom_slots are saved as name arrays (see SaveManager), same
## resource-by-id convention every other saved reference uses.
static func find(ability_name: String) -> Ability:
	return _get_catalog().find(ability_name) as Ability


## Forces a re-scan — same escape hatch SkillDatabase/DemonDatabase
## expose, for a dev/modding workflow that adds or edits an ability
## .tres at runtime. Ordinary play never calls this.
static func refresh() -> void:
	_get_catalog().refresh()


static func _get_catalog() -> ResourceCatalog:
	if not _catalog:
		var extract_id := func(resource: Resource) -> Variant:
			var ability := resource as Ability
			return ability.ability_name if ability else null
		_catalog = ResourceCatalog.new(ABILITIES_DIR, false, extract_id, true, false, false)
	return _catalog
