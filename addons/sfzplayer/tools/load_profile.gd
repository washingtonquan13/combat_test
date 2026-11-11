extends SceneTree

# Times each layer of an ensemble as it loads, to say where an ensemble's start-up goes.
#
#   godot --headless --path . --audio-driver Dummy \
#       -s res://addons/sfzplayer/tools/load_profile.gd -- --ensemble combo
#
# Uses SfzOfflineRenderer rather than SfzInstrument: the same sfizz load, no
# audio server, no waiting for a player to start mixing.

const ENSEMBLES := "res://ensembles"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var id := _value(args, "--ensemble")
	if id == "":
		id = "combo"

	# --registry DIR: instruments from another registry folder, this run only.
	var registry := _value(args, "--registry")
	if registry != "":
		ProjectSettings.set_setting(SfzSettings.REGISTRY, registry)
	# --pinst-head N: the head kept of each .pinst note, this run only.
	var head := _value(args, "--pinst-head")
	if head != "":
		ProjectSettings.set_setting(SfzSettings.PINST_HEAD, int(head))
	SfzSettings.apply_pinst_head()

	var only := _value(args, "--sfz")
	if only != "":
		var f := _value(args, "--frames")
		_one_file(only, int(f) if f != "" else 8192)
		quit(0)
		return

	var ensemble := SfzEnsemble.load_from(SfzSettings.ensemble_path(id))
	if ensemble == null:
		print("no ensemble %s" % id)
		quit(1)
		return

	var renderer := SfzOfflineRenderer.new()
	renderer.configure(44100)

	var total := 0.0
	var regions := 0
	var preloaded := 0
	var seen := {}
	var duplicate := 0.0
	print("%-42s %8s %8s %9s" % ["part / sfz", "seconds", "regions", "preload"])
	# In attach order, each part's layers added under its bus, as the
	# conductor adds them: sfizz's load is the same whatever it is called.
	for part: SfzEnsemble.Part in ensemble.attach_order():
		var part_name := part.name
		for layer: SfzEnsemble.Layer in part.layers:
			var frames := SfzSettings.preload_frames(layer.preload_frames)
			# --frames N overrides the preload, to separate the cost of
			# parsing regions from the cost of reading sample heads.
			var forced := _value(args, "--frames")
			if forced != "":
				frames = int(forced)
			var began := Time.get_ticks_usec()
			# SfzInstrument globalizes internally (sfz_instrument.cpp:196);
			# the offline renderer takes the path as given.
			var voice := renderer.add_voice(part.bus,
					ProjectSettings.globalize_path(layer.sfz_path),
					layer.voices, frames, 0.0)
			var took := (Time.get_ticks_usec() - began) / 1000000.0
			var r := renderer.get_region_count(voice)
			var p := renderer.get_preloaded_sample_count(voice)
			total += took
			regions += r
			preloaded += p
			var tag := "%s / %s" % [part_name, layer.sfz_path.get_file()]
			if seen.has(layer.sfz_path):
				duplicate += took
				tag += "  (again)"
			seen[layer.sfz_path] = true
			print("%-42s %8.2f %8d %9d" % [tag.left(42), took, r, p])

	print("")
	print("%d layers, %d regions, %d samples preloaded" % [seen.size(), regions, preloaded])
	print("total %.2fs" % total)
	print("of which %.2fs was an SFZ this ensemble had already loaded" % duplicate)
	quit(0)


func _value(args: PackedStringArray, flag: String) -> String:
	var at := Array(args).find(flag)
	if at < 0 or at + 1 >= args.size():
		return ""
	return args[at + 1]


# --sfz PATH times one file instead of an ensemble, for isolating what a load
# actually costs: same region count against one sample, or one region each
# against many.
func _one_file(path: String, frames: int) -> void:
	var renderer := SfzOfflineRenderer.new()
	renderer.configure(44100)
	var began := Time.get_ticks_usec()
	var voice := renderer.add_voice("lead", ProjectSettings.globalize_path(path),
			32, frames, 0.0)
	var took := (Time.get_ticks_usec() - began) / 1000000.0
	print("%-44s %7.2fs  %6d regions  %6d preloaded" % [path.get_file(), took,
		renderer.get_region_count(voice), renderer.get_preloaded_sample_count(voice)])
