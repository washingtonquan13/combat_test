extends AiTestCase
## Every UnitDefinition in the project can be found by its own id.
##
## This is what a save file depends on and nothing was checking. A record
## is written down as a `definition_id` string, and read back through
## SpawnableUnitDatabase.find(). If that lookup misses, the record loads
## with definition = null — and since a unit's BODY comes from its
## definition, the character reloads invisible.
##
## Which is exactly what happened. The database scanned data/demons/ and
## data/units/ only, so the moment companions and NPCs moved out of scenes
## and into data/companions/ and data/npcs/, every one of them came back
## from a save with no model. The game looked fine until you loaded.
##
## Checked by walking the directories rather than naming ids, so a fifth
## directory — or a definition dropped into an unscanned one — fails here
## instead of failing in somebody's save six months later.

const DIRS := [
	"res://data/demons/",
	"res://data/units/",
	"res://data/companions/",
	"res://data/npcs/",
]


func run() -> void:
	var checked: int = 0
	var unfindable: Array[String] = []
	var idless: Array[String] = []

	for dir_path in DIRS:
		for file in _definition_files(dir_path):
			var definition: UnitDefinition = load(file)
			if definition == null:
				unfindable.append("%s (failed to load)" % file.get_file())
				continue
			if definition.id == "":
				idless.append(file.get_file())
				continue
			checked += 1
			if SpawnableUnitDatabase.find(definition.id) != definition:
				unfindable.append("%s (id '%s')" % [file.get_file(), definition.id])

	check("SETUP: there are definitions in every directory to check",
		checked >= 30, "%d found across %d directories" % [checked, DIRS.size()])

	check("every definition declares an id a save can write down",
		idless.is_empty(),
		"no id: %s — a record referring to one of these loads as null" % ", ".join(idless))

	check("and every one of them is findable by that id",
		unfindable.is_empty(),
		"unfindable: %s — these reload with no definition, and therefore no body" % ", ".join(unfindable))

	# The two directories that caused this. Named explicitly, because the
	# walk above would go quiet if a directory simply stopped existing.
	for required in ["res://data/companions/", "res://data/npcs/"]:
		check("and %s is actually being scanned" % required,
			_definition_files(required).size() > 0
				and SpawnableUnitDatabase.get_all().any(
					func(d): return d.resource_path.begins_with(required)),
			"nothing from %s is in the database" % required)


func _definition_files(dir_path: String) -> Array[String]:
	var found: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return found
	for file in dir.get_files():
		# .remap in an exported build, the way the test runner's own scan
		# already accounts for.
		if file.ends_with(".tres.remap"):
			file = file.trim_suffix(".remap")
		if file.ends_with(".tres"):
			found.append(dir_path + file)
	return found
