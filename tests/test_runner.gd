extends Node
## Headless entry point for the combat-AI regression suite.
##
##   Godot_v4.4.1-stable_win64_console.exe --path . --headless res://tests/test_runner.tscn
##
## Exits 0 when everything passes and 1 when anything fails, so this is
## usable from a script or CI without parsing the output. Discovers cases
## by scanning tests/ai/ — adding a file is the whole registration step.
##
## Run as its own SCENE rather than an autoload. Autoloads were the old
## convention for headless checks here and they carry a real hazard: the
## wiring lives in project.godot, so a suite that isn't cleaned up
## perfectly leaves a line behind that breaks the actual game on launch.
## That happened during this system's development. A scene has no such
## coupling, and it can't run by accident — the game's own main scene is
## untouched.

const TEST_ROOT: String = "res://tests"


func _ready() -> void:
	# Autoloads still initialise for a directly-run scene, which the AI
	# needs (CombatManager.in_combat, SystemLog, ...). One process frame
	# lets them finish their own _ready before anything is asked of them.
	await get_tree().process_frame

	var total_passes: int = 0
	var total_failures: PackedStringArray = []
	var suites: int = 0

	print("")
	print("=== combat AI regression suite ===")

	for path in _discover():
		var script: GDScript = load(path)
		if script == null:
			total_failures.append("%s failed to load" % path)
			continue

		var test_case = script.new()
		if not (test_case is AiTestCase):
			test_case.free()
			continue

		suites += 1
		var name: String = path.get_file().get_basename()
		# Printed BEFORE the run, and flushed, so a hard engine crash still
		# names the suite that caused it instead of leaving a silent gap.
		print("  .... %s" % name)
		add_child(test_case)
		await test_case.setup()
		await test_case.run()

		if test_case.failures.is_empty():
			print("  ok    %-28s %d checks" % [name, test_case.passes])
		else:
			print("  FAIL  %-28s %d passed, %d failed" % [
				name, test_case.passes, test_case.failures.size()])
			for failure in test_case.failures:
				print("          - %s" % failure)
				total_failures.append("%s: %s" % [name, failure])

		total_passes += test_case.passes
		await test_case.teardown()
		test_case.queue_free()

	print("")
	if total_failures.is_empty():
		print("PASSED  %d checks across %d suites" % [total_passes, suites])
		get_tree().quit(0)
	else:
		print("FAILED  %d of %d checks across %d suites" % [
			total_failures.size(), total_passes + total_failures.size(), suites])
		get_tree().quit(1)


## Every .gd under a SUBDIRECTORY of tests/ — so tests/ai/, tests/detection/
## and whatever comes next are all picked up without touching this file
## again. Deliberately skips tests/ itself: ai_test_case.gd and this runner
## live there and are machinery, not cases.
func _discover() -> PackedStringArray:
	var found: PackedStringArray = []
	for directory in DirAccess.get_directories_at(TEST_ROOT):
		var path: String = "%s/%s" % [TEST_ROOT, directory]
		for file in DirAccess.get_files_at(path):
			# Godot hands back .remap for exported builds; .gd is what
			# matters and stripping the suffix works either way.
			if file.ends_with(".gd.remap"):
				file = file.trim_suffix(".remap")
			if file.ends_with(".gd"):
				found.append("%s/%s" % [path, file])
	found.sort()
	# `./tests/run.sh --suite=<substring>` (any number of them) runs only the
	# suites whose file name contains one of the substrings. A full run
	# takes minutes now that suites stand up real worlds; a sabotage check
	# needs one suite, not all of them.
	var wanted: PackedStringArray = []
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--suite="):
			wanted.append(arg.trim_prefix("--suite="))
	if not wanted.is_empty():
		var kept: PackedStringArray = []
		for path in found:
			for want in wanted:
				if path.get_file().contains(want):
					kept.append(path)
					break
		found = kept
	return found
