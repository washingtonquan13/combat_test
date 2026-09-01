class_name SpawnableUnitDatabase
extends RefCounted
## Every UnitDefinition in the project — everything under data/units/, at
## any depth — combined into one flat list.
##
## It began as "everything the debug spawn tool could plausibly place",
## which is still what get_all() is for. find() is a later and much less
## optional job: it is how a SAVE FILE turns a definition_id back into a
## definition, for party members (PartyManager._load_one) and for recruited
## demons (DemonRoster). A directory missing from the list below is not a
## gap in a debug menu — it is a saved character coming back with no
## definition, and therefore no BODY, because that is where a unit's model
## comes from.
##
## That is exactly what happened when companions and NPCs moved out of
## scenes and into data/: their definitions resolved to null on load and
## every one of them reloaded invisible. Deliberately NOT merged into
## DemonDatabase (see that file) and deliberately NOT id-keyed the way
## DemonDatabase is — nothing here needs single-id lookup yet (the spawn
## panel only ever wants "all of them"), and an id-keyed cache would
## silently let two definitions sharing an id overwrite each other; a flat
## array can't have that failure mode.
##
## Stateless from the outside — static, no instances, not an autoload —
## same reasoning as DemonDatabase.

## One root, walked recursively — demons/, companions/, npcs/, summons/ and
## whatever comes next. Deliberately NOT a list of directories: a hardcoded
## list is what caused every companion and NPC to reload invisible the day
## they moved out of scenes and into data/, because a directory missing
## from that list resolves its ids to null and a unit with no definition
## has no BODY. A subfolder added under here is covered by existing.
const ROOT_DIR: String = "res://data/units/"

static var _all: Array[UnitDefinition] = []


static func get_all() -> Array[UnitDefinition]:
	if _all.is_empty():
		_load_all()
	return _all


## Null if no definition with this id exists in either directory. A
## linear scan, deliberately not a cached id->definition dict — see this
## file's own header on why a flat array is kept instead of one: an id
## collision between demons/ and units/ is a pre-existing authoring risk
## either way, and this returns whichever this array happens to hold
## first rather than letting one silently overwrite the other in a
## cache. Needed for save/load: PartyMemberData.definition is saved as
## an id (see SaveManager), and a saved leader/companion can come from
## EITHER directory — DemonDatabase.find() alone can't resolve a
## units/-sourced definition.
static func find(id: String) -> UnitDefinition:
	if _all.is_empty():
		_load_all()
	for definition in _all:
		if definition.id == id:
			return definition
	return null


static func refresh() -> void:
	_all.clear()
	_load_all()


static func _load_all() -> void:
	var pending: Array[String] = [ROOT_DIR]
	while not pending.is_empty():
		var dir: String = pending.pop_back()
		for sub in DirAccess.get_directories_at(dir):
			pending.append(dir + sub + "/")
		for file_name in DirAccess.get_files_at(dir):
			# Godot hands back .remap in an exported build; .tres is what
			# actually opens.
			if file_name.ends_with(".tres.remap"):
				file_name = file_name.trim_suffix(".remap")
			if not file_name.ends_with(".tres"):
				continue
			var definition := load(dir + file_name) as UnitDefinition
			if definition:
				_all.append(definition)
