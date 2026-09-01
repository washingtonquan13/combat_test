extends AiTestCase
## Every UnitDefinition anywhere under data/ can be found by its own id.
##
## This is what a save file depends on and nothing was checking. A record is
## written down as a `definition_id` string and read back through
## SpawnableUnitDatabase.find(). If that lookup misses, the record loads
## with definition = null — and since a unit's BODY comes from its
## definition, the character reloads invisible. The game looks correct right
## up until you load it, which is why nothing caught it.
##
## That is what happened when companions and NPCs moved out of scenes into
## data/companions/ and data/npcs/: the database scanned data/demons/ and
## data/units/ only, so every one of them came back from a save with no
## model.
##
## WHY THIS WALKS THE TREE INSTEAD OF NAMING DIRECTORIES. The first version
## of this suite checked a hardcoded list of four — the same four the
## database hardcodes. A guard that only guards what you already remembered
## is not a guard: add data/bosses/ tomorrow and the scanner misses it, this
## test misses it too, and you find out from a save.
##
## So it finds definitions by reading what each file says it is. A new
## directory, or a definition dropped anywhere at all, is covered by
## existing rather than by somebody remembering to add it here.

const ROOT := "res://data/"
## A floor, so an empty or broken walk cannot pass by finding nothing.
const AT_LEAST := 30


func run() -> void:
	var files: Array[String] = _definition_files_under(ROOT)

	check("SETUP: the walk actually finds the project's definitions",
		files.size() >= AT_LEAST,
		"%d found under %s — expected at least %d, so the walk is broken " % [
			files.size(), ROOT, AT_LEAST] +
		"rather than the database")

	var idless: Array[String] = []
	var unfindable: Array[String] = []
	var directories: Dictionary = {}

	for path in files:
		directories[path.get_base_dir() + "/"] = true
		var definition: UnitDefinition = load(path)
		if definition == null:
			unfindable.append("%s (failed to load)" % path.get_file())
			continue
		if definition.id == "":
			idless.append(path.get_file())
			continue
		if SpawnableUnitDatabase.find(definition.id) != definition:
			unfindable.append("%s (id '%s')" % [path.get_file(), definition.id])

	check("every definition declares an id a save can write down",
		idless.is_empty(),
		"no id: %s — a record referring to one of these loads as null" % ", ".join(idless))

	check("and every one of them is findable by that id",
		unfindable.is_empty(),
		"unfindable: %s — these reload with no definition, and therefore " % ", ".join(unfindable) +
		"no body. A directory holding definitions is missing from " +
		"SpawnableUnitDatabase's scan list.")

	# Reported rather than asserted: the point is that the count is not
	# fixed. A fifth directory should make this line longer and change
	# nothing else, which is the whole reason the walk exists.
	var listed: Array = directories.keys()
	listed.sort()
	print("        definitions live in: %s" % ", ".join(listed))


## Every .tres under `root`, at any depth, that says it is a UnitDefinition.
func _definition_files_under(root: String) -> Array[String]:
	var found: Array[String] = []
	var pending: Array[String] = [root]
	while not pending.is_empty():
		var dir_path: String = pending.pop_back()
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		for sub in dir.get_directories():
			pending.append(dir_path + sub + "/")
		for file in dir.get_files():
			# Godot hands back .remap in an exported build; .tres is what
			# opens — the same allowance the test runner's own scan makes.
			if file.ends_with(".tres.remap"):
				file = file.trim_suffix(".remap")
			if file.ends_with(".tres") and _declares_unit_definition(dir_path + file):
				found.append(dir_path + file)
	return found


## Read, don't load.
##
## A resource announces its script_class on the first line, and reading that
## line is far cheaper — and far safer — than instantiating every .tres
## under data/ (abilities, skills, items, statuses, whole dialogue trees)
## purely to ask what type each one is.
func _declares_unit_definition(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var header: String = file.get_line()
	file.close()
	return header.contains('script_class="UnitDefinition"')
