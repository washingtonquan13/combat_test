extends AiTestCase
## Every script in the project parses.
##
## Cheap, and it covers a gap the rest of this suite structurally cannot:
## these tests only ever load the scripts they exercise. party_panel.gd,
## the HUD, the hotbar — nothing here instantiates them, so a rename that
## misses a call site in one of them is invisible until the game is booted
## and that panel happens to refresh.
##
## Which is exactly how `group.area_id` survived the rename pass: 346 green
## checks, and the first attempt to travel with a party in the real game
## threw on the one reader nothing here loads.

## .godot holds import artefacts, not source. addons are editor plugins
## that expect an EditorInterface headless does not provide. gdextension
## vendors godot-cpp, whose own test project is written against classes
## that do not exist here and is not ours to keep parseable.
const SKIP: Array[String] = ["res://.godot", "res://addons", "res://gdextension"]


func run() -> void:
	var scripts: PackedStringArray = _every_script("res://")
	var broken: Array[String] = []

	for path in scripts:
		# Plain load(), which REUSES the cache. Forcing a fresh parse with
		# CACHE_MODE_IGNORE recompiles scripts that are live — autoloads
		# included — and it corrupted the VM mid-run when tried: "Internal
		# script error! Opcode: 95" out of music_manager, in a later suite.
		# The cache is not a problem here anyway: the scripts this exists to
		# cover are precisely the ones nothing else has loaded.
		if load(path) == null:
			broken.append(path.trim_prefix("res://"))

	check("every script in the project parses (%d scanned)" % scripts.size(),
		broken.is_empty(), ", ".join(broken))
	check("and there were scripts to scan",
		scripts.size() > 50, "found only %d" % scripts.size())


func _every_script(root: String) -> PackedStringArray:
	var found: PackedStringArray = []
	if SKIP.has(root):
		return found
	# "res://" already ends in a separator and every other path does not;
	# joining both the same way yields "res:///.godot", which matches no
	# skip entry and walks the import cache.
	var base: String = root if root.ends_with("/") else root + "/"
	for directory in DirAccess.get_directories_at(root):
		found.append_array(_every_script(base + directory))
	for file in DirAccess.get_files_at(root):
		if file.ends_with(".gd.remap"):
			file = file.trim_suffix(".remap")
		if file.ends_with(".gd"):
			found.append(base + file)
	return found
