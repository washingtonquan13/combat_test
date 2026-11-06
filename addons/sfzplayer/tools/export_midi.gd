extends SceneTree

# A score out as a MIDI file, from the command line:
#
#   godot --headless --path . -s res://addons/sfzplayer/tools/export_midi.gd -- \
#       res://music/scores/battle.score
#
# writes battle.mid beside the score. After the `--`:
#
#   <score>              a path, or a score id from the scores folder
#   --out  path.mid      somewhere else to write it
#   --ensemble id            an ensemble other than the score's own ensemble: header
#   --literal            the notes as written, on the grid, instead of as
#                        the engine performs them
#   --no-keyswitches     leave articulation keyswitches out, for a file going
#                        to instruments that are not this ensemble's libraries
#
# See SfzMidiExport for what goes in the file. The same export is in the
# editor under Project > Tools > Export Score to MIDI.


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var score_path := ""
	var out_path := ""
	var ensemble_id := ""
	var export := SfzMidiExport.new()
	var i := 0
	while i < args.size():
		var arg := args[i]
		match arg:
			"--out":
				i += 1
				out_path = args[i] if i < args.size() else ""
			"--ensemble":
				i += 1
				ensemble_id = args[i] if i < args.size() else ""
			"--literal":
				export.compiler = SfzScoreCompiler.new()
			"--no-keyswitches":
				export.keyswitches = false
			_:
				if arg.begins_with("--"):
					return _fail("unknown option %s" % arg)
				score_path = arg
		i += 1

	if score_path == "":
		return _fail("which score? give a path or a score id after --")
	if not score_path.ends_with(".score"):
		score_path = SfzSettings.score_path(score_path)
	elif not score_path.contains("://") and not score_path.is_absolute_path():
		score_path = "res://" + score_path
	if out_path == "":
		out_path = score_path.get_basename() + ".mid"

	var problem := export.write_file(score_path, out_path, ensemble_id)
	if problem != "":
		return _fail(problem)
	print("%s -> %s" % [score_path, ProjectSettings.globalize_path(out_path)])
	print("  %s, %s" % [export.compiler.describe(), export.summary()])
	quit(0)


func _fail(message: String) -> void:
	printerr("export_midi: " + message)
	quit(1)
