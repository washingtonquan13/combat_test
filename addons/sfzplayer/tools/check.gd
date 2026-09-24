extends SceneTree

# Asks, without making a sound, what an ensemble would do with a score.
#
#   godot --headless --path . --audio-driver Dummy \
#       -s res://addons/sfzplayer/tools/check.gd -- --score sealed-ward
#
# A SceneTree rather than a scene, like scripts/golden_test.gd beside it: no
# audio device, no frames, no main loop to idle in - _initialize runs, prints
# and quits.
#
# The engine is deliberately fail-open. A kit with no ride sits the ride out
# (conductor.gd:280), a piano with no vibrato ignores the vibrato
# (conductor.gd:341), a note below the lowest sample is folded up an octave
# (ensemble.gd:186). Every one of those is the right call at runtime - a score
# should be free to write for an ensemble that cannot hear all of it, and thin out
# rather than fail. None of them is the right call at four in the afternoon
# when a part has gone missing and nothing has said so.
#
# So this is the other half of that design: the same questions the conductor
# asks per event, asked once, ahead of time, out loud.
#
# It never loads a sample. SfzEnsemble.load_from only checks a layer's SFZ exists
# (ensemble.gd:325), the compiler needs no audio, and the event stream comes from
# the same SfzPerformanceCompiler the game runs. A whole matrix of every score
# against every ensemble is one Godot boot and a few seconds.
#
# Command line, after a bare `--`:
#
#   --score NAME    one score, else all of scores/; a path to a .score
#                   file is read from there (the test's fixture is one)
#   --ensemble NAME     one ensemble, else the score's own; a path to a .json too
#   --matrix        every score against every ensemble, as a grid
#   --quiet         the verdict lines only, no per-finding detail
#   --verbose       every voiced lane's route, one line each, as well
#   --folds-fail    treat octave-folded notes as a failure, not a remark
#   --impact WHAT   the blast radius of a change to WHAT, below; checks
#                   no score. --since REV narrows a registry file, or
#                   `registry` for all of them, to the instruments that
#                   differ from REV
#
# On folding: a folded note is not lost - it sounds, an octave from where it
# was written - so it is not counted as lost. It is not nothing either: two
# hundred bass notes jumping an octave is a different piece. So it is printed
# on every verdict line, pass or fail, broken down by part, and --folds-fail
# makes it a non-zero exit for a score under its own ensemble. The breakdown is
# printed whenever that gate fails a score, --quiet or not.
#
# On casting: each part the score declares is played by the ensemble part
# SfzEnsemble.resolve finds for it (docs/REGISTRY.md §6) - its own name, its
# family's default, its player's part (a co-part), the family's fallback, or
# nothing.
# Anything past its own name is legitimate, so it is not a loss unless
# nothing plays it - but it recasts a line, and a recast nobody mentions is
# how decadence's choir once stopped being a choir for half the piece. So
# one "cast" line names every part with events that went past step 1, where
# it landed and by which step, a co-part on its player's part included.
# --verbose names every part, step 1 too.
#
# On bends: a bend goes only as far as SfzScoreCompiler.bend_reach - the
# pitch wheel's bend_range on a part with no "bend" control, and the
# control's own 1200 cents on any part. Past that it still sounds, cut
# short, so it is not a loss; each lane that does it prints how many
# messages and the deepest bend as written. "Past" is bend_cut, the test the
# compiler warns on, applied to the same written cents (Probe tags each bend
# message with them), so this and the compiler's warning agree about a
# 201-cent bend on a 200-cent wheel.
#
# On warnings: every "warns:" line is one of the player's own per-ensemble
# warnings (SfzScorePlayer._report), in its words less the score's name -
# what a game would see in its log at prepare(), printed here every time
# rather than once a run. They are not failures: a fallback still sounds,
# and a drop is already in the verdict above them.
#
# On --impact: what a change to an instrument would reach, before it is
# made and without a sound (docs/REGISTRY.md §8). WHAT is an instrument id
# (vpo/choir-female), a registry file (registry/vpo.json), `registry` for
# every registry file, or an SFZ or cabinet path under samples/ - or several
# of those joined by commas. It prints the instruments concerned, the
# ensembles and parts that use them, the scores and music/transitions.json
# areas that play those ensembles, every other score-on-ensemble pairing
# with a part that resolves onto those parts, and the run_tests.py line for
# the tests that would hear the change. An id the registry does not define,
# and an ensemble that no longer loads (one naming an instrument the change
# removed, say), fail the run: "none" has to mean nothing plays it.
#
#   check.gd -- --impact registry --since main    what this branch touched
#
# Exit code is 1 if any score loses an event against its OWN ensemble. A score
# checked against an ensemble it was not written for is reported, never failed:
# "sealed-ward loses its kit under cathedral" is information, not a defect.

const SCORES := "res://scores"
const ENSEMBLES := "res://ensembles"
const PASSES := 2

var _bad := 0
var _fold_gate := false
var _verbose := false


class Recorder extends SfzScorePlayer:
	var log: Array = []

	func _dispatch(event: Dictionary, at: float) -> void:
		log.append(event)

	# The player's per-ensemble warnings are printed from _findings instead, every
	# time they are asked for rather than once a run.
	func _say(_text: String) -> void:
		pass


# The game's compiler, unchanged, except that every bend message also says
# the cents it was written as. The value on the message is quantised to
# 1200/63 cents a step and clamped at 1200, so it cannot tell 200 cents from
# 205, or 1300 from 1200; the written number is what the compiler's own
# warning measures, so it is what the remark measures. Only this tool's
# events carry the tag - the golden stream and the game never see it.
class Probe extends SfzPerformanceCompiler:
	func _emit_bend(out: Array, part: String, t: float, cents: float) -> void:
		super(out, part, t, cents)
		out[-1]["cents"] = cents


# What one ensemble would do with one score's events.
class Verdict:
	var events := 0
	var lost := 0            # events that reach nothing at all
	var folded := 0          # notes moved by octaves to reach a sample
	var drums := {}          # lane/drum -> count the kit cannot play
	var controls := {}       # lane/control -> count nobody hears
	var arts := {}           # lane/art -> count with no keyswitch
	var parts := {}          # score part -> count nothing in the ensemble plays
	var folds := {}          # score part -> count folded by octaves
	# Not losses - reported so that a quiet recast is visible:
	var cast := {}           # score part -> {part, step, family, with_player, events}
	var bends := {}          # lane -> [count, deepest cents, reach, by what]
	# The player's own per-ensemble warnings for this score and ensemble, the words a
	# game would see at prepare(), without the score's name in front.
	var warnings: Array = []

	func sounding() -> int:
		return events - lost

	func ok() -> bool:
		return lost == 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var quiet := "--quiet" in args
	var matrix := "--matrix" in args
	_fold_gate = "--folds-fail" in args
	_verbose = "--verbose" in args
	if "--impact" in args:
		_impact(_value(args, "--impact"), _value(args, "--since"))
		quit(1 if _bad else 0)
		return
	var one_score := _value(args, "--score")
	var one_ensemble := _value(args, "--ensemble")

	var scores := _score_ids()
	if one_score != "":
		scores = [one_score if one_score.ends_with(".score")
			else one_score.get_file().get_basename()]
	if scores.is_empty():
		print("no scores to check")
		quit(1)
		return

	if matrix:
		_matrix(scores, _ensemble_ids())
	else:
		for id in scores:
			_one(id, one_ensemble, quiet)

	quit(1 if _bad else 0)


# --- One score, one ensemble ---------------------------------------------------

func _one(id: String, ensemble_id: String, quiet: bool) -> void:
	var path := id if id.ends_with(".score") else "%s/%s.score" % [SCORES, id]
	id = id.get_file().get_basename()
	var score := SfzScoreParser.parse_file(path)
	if score == null:
		print("%s: does not parse" % id)
		_bad += 1
		return
	var native := score.ensemble_id if score.ensemble_id != "" else "combo"
	var use := ensemble_id if ensemble_id != "" else native
	var ensemble := SfzEnsemble.load_from(use if use.ends_with(".json")
		else SfzSettings.ensemble_path(use))
	use = use.get_file().get_basename()
	if ensemble == null:
		print("%s: ensemble %s does not load" % [id, use])
		_bad += 1
		return

	var v := _judge(ensemble, score)
	var where := use if use == native else "%s (written for %s)" % [use, native]
	if v.ok():
		print("%s under %s: all %d events sound%s" % [id, where, v.events,
			("" if v.folded == 0 else ", %d notes folded into range" % v.folded)])
		# A fold is not a loss, but it is not nothing: say where it happened
		# unless asked for verdicts only, and fail on it when asked to.
		var gated := _fold_gate and use == native and v.folded > 0
		if gated:
			_bad += 1
		# Folds, when asked verdicts only, still print if they failed the run:
		# a non-zero exit with nothing to say why is the thing to avoid.
		if gated or (v.folded > 0 and not quiet):
			_folds(v)
		if not quiet:
			_remarks(v, ensemble)
			_warnings(v)
		return

	print("%s under %s: %d of %d events sound, %d lost (%.0f%%)" % [id, where,
		v.sounding(), v.events, v.lost, 100.0 * v.lost / maxi(v.events, 1)])
	# Only its own ensemble is a defect. Another ensemble's shortfall is the answer to
	# a question, and the question was "would this piece survive over there".
	if use == native:
		_bad += 1
	if quiet:
		if _fold_gate and use == native and v.folded > 0:
			_folds(v)
		return
	for part_name in v.parts:
		print("    nothing in the ensemble plays part '%s': %d events" % [
			part_name, v.parts[part_name]])
	for drum in v.drums:
		print("    the kit has no '%s': %d hits" % [drum, v.drums[drum]])
	for art in v.arts:
		print("    no keyswitch for %s: %d changes" % [art, v.arts[art]])
	for control in v.controls:
		print("    nobody hears %s: %d messages" % [control, v.controls[control]])
	if v.folded > 0:
		_folds(v)
	_remarks(v, ensemble)
	_warnings(v)


# What SfzScorePlayer says at prepare() about this score on this ensemble
# (SfzScorePlayer._report): the same items, in the same words, here each
# time rather than once a run.
func _warnings(v: Verdict) -> void:
	for text: String in v.warnings:
		print("    warns: %s" % text)


# What sounds but not as written: how each part is cast, and bends cut short.
func _remarks(v: Verdict, ensemble: SfzEnsemble) -> void:
	var line := _casting(v)
	if line != "":
		print("    cast on %s: %s" % [ensemble.id, line])
	for lane in v.bends:
		var b: Array = v.bends[lane]
		print("    %s bends past its reach (%d cents, %s) %d times, deepest %d cents; cut short there" % [
			lane, int(b[2]), b[3], b[0], int(round(b[1]))])


# The resolution report as one line, or "" when it carries no news: every
# part with events that the ensemble plays under another name, in the
# score's order, as "high -> pad (family fallback)". The news is the same as
# the player's own "cast" warning, and the exception is its exception: a
# part with no events. --verbose
# names every part, so the whole cast can be read off one line.
func _casting(v: Verdict) -> String:
	var said: Array = []
	for part_name: String in v.cast:
		var c: Dictionary = v.cast[part_name]
		var step := int(c["step"])
		if not _verbose and (step == 1 or int(c["events"]) == 0):
			continue
		var landed: String = c["part"] if c["part"] != "" else "nothing"
		if step == 1:
			said.append("%s -> %s" % [part_name, landed])
		else:
			said.append("%s (%s) -> %s (%s)" % [part_name, c["family"], landed,
				SfzScorePlayer.STEP_WORDS.get(step, "")])
	return ", ".join(said)


# The furthest step any part with events was cast by, counting as the report
# does; 1 when every part plays under its own name.
func _furthest(v: Verdict) -> int:
	var furthest := 1
	for c: Dictionary in v.cast.values():
		if int(c["events"]) > 0:
			furthest = maxi(furthest, int(c["step"]))
	return furthest



# Where the octave folding happened, part by part.
func _folds(v: Verdict) -> void:
	for part_name in v.folds:
		print("    %d notes folded by octaves to reach a sample: %s" % [
			v.folds[part_name], part_name])


# The conductor's own questions, asked without an instrument behind them.
func _judge(ensemble: SfzEnsemble, score: SfzScore) -> Verdict:
	var v := Verdict.new()
	var conductor := SfzConductor.new()
	conductor.ensemble = ensemble
	var player := Recorder.new(conductor)
	player.compiler = Probe.new()
	player.loop_passes = PASSES
	player._prepare(score)
	var who := (score.id if score.id != "" else score.title) + ": "
	for key: String in player._findings:
		var text: String = player._findings[key]["text"]
		v.warnings.append(text.trim_prefix(who))
	player._pump(INF)

	# The cast the player sends by: SfzEnsemble.cast, once, as prepare() does.
	var cast := ensemble.cast(score.parts)
	for part_name: String in cast:
		v.cast[part_name] = {"part": cast[part_name]["part"],
			"step": int(cast[part_name]["step"]),
			"family": score.parts[part_name].get("family", part_name),
			"events": 0}

	for event in player.log:
		# A note off is bookkeeping; counting it doubles every loss.
		if event["kind"] == "off":
			continue
		var part_name: String = event.get("part", "")
		# The lane by its performance name, which is what a reader wrote.
		var lane: String = event.get("perf", part_name)
		var cast_as: Dictionary = cast.get(part_name, {"part": part_name, "step": 1})
		var part := ensemble.part(cast_as["part"])
		v.events += 1
		if v.cast.has(part_name):
			v.cast[part_name]["events"] += 1
		# Before anything the part can answer: does the event reach a player
		# at all? A part resolved to nothing is the empty part, no layers.
		if part.layers.is_empty():
			v.lost += 1
			v.parts[part_name] = int(v.parts.get(part_name, 0)) + 1
			continue
		match event["kind"]:
			"note":
				if not part.covers(int(event["key"])):
					v.folded += 1
					v.folds[part_name] = int(v.folds.get(part_name, 0)) + 1
			"hit":
				if part.key_for(event["drum"]) < 0:
					v.lost += 1
					var d: String = "%s/%s" % [lane, event["drum"]]
					v.drums[d] = int(v.drums.get(d, 0)) + 1
			"art":
				# Part.switches is the conductor's walk, and the compiler asks
				# it before it writes a keyswitch, so a performed score gets
				# here only for a key the part lacks.
				if not part.switches(event["art"]):
					v.lost += 1
					var a: String = "%s/%s" % [lane, event["art"]]
					v.arts[a] = int(v.arts.get(a, 0)) + 1
			"cc":
				if event["control"] == "bend" and event.has("cents"):
					_bend(v, part, lane, float(event["cents"]))
				if not _heard(part, event["control"]):
					v.lost += 1
					var c: String = "%s/%s" % [lane, event["control"]]
					v.controls[c] = int(v.controls.get(c, 0)) + 1
			_:
				pass

	conductor.free()
	player.free()
	return v


# A bend message, as written, against how far the part can bend. The test
# is SfzScoreCompiler.bend_cut, the compiler warning's own.
func _bend(v: Verdict, part: SfzEnsemble.Part, lane: String, cents: float) -> void:
	if not SfzScoreCompiler.bend_cut(cents, part):
		return
	var reach := SfzScoreCompiler.bend_reach(part)
	# What stops it: a part's own control, or the wheel it is played on -
	# unless the wheel reaches further than the control the bend is written
	# on (bend_range over BEND_RANGE), when that control's range is the stop
	# even though the part has no control of its own.
	var by := "bend control"
	if part.cc("bend") < 0:
		by = "pitch wheel" if reach == part.bend_range \
			else "pitch wheel, held to the bend control's range"
	var b: Array = v.bends.get(lane, [0, 0.0, reach, by])
	b[0] += 1
	if absf(cents) > absf(b[1]):
		b[1] = cents
	v.bends[lane] = b


# The rule lives in SfzEnsemble.Part.hears(), which render.gd's --show and --xref
# call too, so the two tools cannot disagree about what a part hears. A bend
# with no control of its own is heard by any part with layers, which the
# caller has established; heard is not whole, though: a bend stops at
# bend_reach, and _bend reports one written past it.
func _heard(part: SfzEnsemble.Part, control: String) -> bool:
	return part.hears(control)


# --- Every score against every ensemble ----------------------------------------

func _matrix(scores: Array, ensembles: Array) -> void:
	# Parse and load once each: the grid is 120 cells and the compile is the
	# expensive half.
	var parsed := {}
	for id in scores:
		var score := SfzScoreParser.parse_file("%s/%s.score" % [SCORES, id])
		if score != null:
			parsed[id] = score
	var loaded := {}
	for b in ensembles:
		var ensemble := SfzEnsemble.load_from(SfzSettings.ensemble_path(b))
		if ensemble != null:
			loaded[b] = ensemble

	var head := "%-22s" % "score \\ ensemble"
	for b in loaded:
		head += "%10s" % (b as String).left(9)
	print(head)
	for id in parsed:
		var score: SfzScore = parsed[id]
		var native := score.ensemble_id if score.ensemble_id != "" else "combo"
		var line := "%-22s" % id
		for b in loaded:
			var v := _judge(loaded[b], score)
			var pct := 100.0 * v.sounding() / maxf(v.events, 1)
			var cell := "%.0f%%" % pct
			var step := _furthest(v)
			if step > 1:
				cell += str(step)   # a part cast past its own name
			if not v.bends.is_empty():
				cell += "~"   # a bend the pitch wheel cuts short
			if b == native:
				cell = "[%s]" % cell   # the ensemble it was written for
				if not v.ok():
					_bad += 1
			line += "%10s" % cell
		print(line)
	print("")
	print("percentage of the score's events that reach an instrument.")
	print("[brackets] mark the ensemble the score names in its header.")
	print("a digit is the furthest resolution step a part with events took:")
	print("  2 family default, 3 its player's part, 4 family fallback, 5 nothing.")
	print("~ marks a bend written past the part's pitch wheel; it stops there.")


# --- Blast radius ----------------------------------------------------------

# The five lists of docs/REGISTRY.md §8, in order. Reads manifests, scores
# and music/transitions.json; opens no SFZ and loads no sample.
#
# WHAT is one target or several joined by commas, so a commit that touched
# two registry files is asked about once, and its reach is read as one list
# rather than two that overlap. `registry` on its own is every registry
# file, which with --since is "whatever the registry changed since REV".
func _impact(what: String, since: String) -> void:
	if what == "":
		print("--impact needs an instrument id, a registry file, or an SFZ or cabinet path")
		_bad += 1
		return

	# 1. The instruments. A path is matched on the layers that play it, so a
	# cabinet an ensemble's own layer entry names counts as well as one the
	# registry names.
	var concerned := {}
	var files: Array = []   # samples, spelled as Layer.take_key spells them
	for target: String in what.split(",", false):
		target = target.strip_edges()
		if _is_sample_path(target):
			var file := _sample_key(target)
			files.append(file)
			for id: String in _registry_files(file):
				concerned[id] = true
		elif target.trim_prefix("res://").trim_suffix("/") == "registry":
			for library in _libraries_since(since):
				for id: String in _changed_instruments(
						"registry/%s.json" % library, since):
					concerned[id] = true
		elif target.ends_with(".json"):
			if not FileAccess.file_exists(SfzSettings.registry_path(
					target.get_file().get_basename())) and since == "":
				print("no registry file %s" % target)
				_bad += 1
				continue
			for id: String in _changed_instruments(target, since):
				concerned[id] = true
		elif _defined(target):
			concerned[target] = true
		else:
			# An id nothing defines reaches nothing, and saying "none" to it
			# would read as "safe to change" - a typo is not that.
			print("no instrument %s in the registry" % target)
			_bad += 1

	var ensembles := {}     # id -> SfzEnsemble
	var broken: Array = []  # ensembles that do not load: the change may be why
	for b in _ensemble_ids():
		var ensemble := SfzEnsemble.load_from(SfzSettings.ensemble_path(b), false)
		if ensemble != null:
			ensembles[b] = ensemble
		else:
			broken.append(b)
	for b: String in ensembles:
		for p: SfzEnsemble.Part in (ensembles[b] as SfzEnsemble).parts.values():
			for layer: SfzEnsemble.Layer in p.layers:
				for file: String in files:
					if _plays_file(layer, file):
						concerned[layer.instrument] = true
	var ids := concerned.keys()
	ids.sort()
	print("instruments:")
	if ids.is_empty():
		print("    none concerned by %s" % what)
	for id in ids:
		print("    %s" % id)

	# 2. The ensembles and their parts.
	var used := {}          # ensemble id -> [part names]
	for b: String in ensembles:
		for p: SfzEnsemble.Part in (ensembles[b] as SfzEnsemble).parts.values():
			for layer: SfzEnsemble.Layer in p.layers:
				var hit := concerned.has(layer.instrument)
				for file: String in files:
					hit = hit or _plays_file(layer, file)
				if hit:
					if not used.has(b):
						used[b] = []
					if not p.name in used[b]:
						(used[b] as Array).append(p.name)
	print("ensembles:")
	if used.is_empty():
		print("    none")
	for b: String in used:
		print("    %s: %s" % [b, ", ".join(used[b])])
	# An ensemble that does not load cannot say what it uses, and one that
	# named an instrument the change removed is exactly this: it is named,
	# and it fails the run, rather than left out of the lists.
	if not broken.is_empty():
		print("    does not load (see the error above): %s" % ", ".join(broken))
		_bad += broken.size()

	# 3. The scores written for those ensembles, and the areas that play one.
	var parsed := {}
	for id in _score_ids():
		var score := SfzScoreParser.parse_file("%s/%s.score" % [SCORES, id])
		if score != null:
			parsed[id] = score
	var own: Array = []
	for id: String in parsed:
		var home := (parsed[id] as SfzScore).ensemble_id
		if used.has(home) or home in broken:
			own.append(id)
	print("scores:")
	if own.is_empty():
		print("    none")
	for id: String in own:
		print("    %s (%s)" % [id, (parsed[id] as SfzScore).ensemble_id])
	var areas: Variant = JSON.parse_string(
		FileAccess.get_file_as_string("res://music/transitions.json"))
	if areas is Dictionary:
		var table: Dictionary = areas.get("areas", {})
		for area: String in table:
			var entry: Dictionary = table[area]
			var ensemble := String(entry.get("ensemble", ""))
			if used.has(ensemble) or ensemble in broken:
				print("    area %s (%s, %s)" % [area, ensemble, entry.get("score", "")])

	# 4. Every score, on every ensemble but its own, with a part - one it
	# writes lanes for - that resolves onto one of those parts there. A score
	# in 3 counts here too: decadence played on groovy reaches groovy's pad
	# as surely as a stranger does. A part with no lanes plays nothing
	# anywhere, so it is left out.
	print("other pairings that resolve onto them:")
	var others := 0
	for id: String in parsed:
		var score: SfzScore = parsed[id]
		var written := _written_parts(score)
		for b: String in used:
			if b == score.ensemble_id:
				continue
			var cast := (ensembles[b] as SfzEnsemble).cast(score.parts)
			for part_name: String in cast:
				var landed: String = cast[part_name]["part"]
				if written.has(part_name) and landed in used[b]:
					print("    %s: %s -> %s/%s (step %d)" % [id, part_name, b, landed,
						int(cast[part_name]["step"])])
					others += 1
	if others == 0:
		print("    none")

	# 5. The tests that would hear it. golden runs both hashes itself.
	print("tests:")
	if used.is_empty() and broken.is_empty():
		print("    none: nothing plays it")
		return
	var tests: Array = ["golden", "warnings"]
	if not own.is_empty():
		tests.append("loudness")
	for field in _fields_of(ids):
		if not field in tests:
			tests.append(field)
	print("    python tools/run_tests.py %s" % " ".join(tests))


# Whether an instrument id names one the registry defines now.
func _defined(id: String) -> bool:
	var split := id.split("/", true, 1)
	return split.size() == 2 and 		(_registry(split[0]).get("instruments", {}) as Dictionary).has(split[1])


# The libraries to read for `registry`: every file there now, and with
# `since` every file REV had as well, so a library deleted since is asked
# about and its instruments come back as lost.
func _libraries_since(since: String) -> Array:
	var out := _libraries()
	if since == "":
		return out
	var git_out: Array = []
	var dir := SfzSettings.registry_path("x").get_base_dir().trim_prefix("res://")
	if OS.execute("git", ["-C", ProjectSettings.globalize_path("res://"),
			"ls-tree", "--name-only", since, dir + "/"], git_out, true) == 0:
		for line: String in String(git_out[0]).split("
", false):
			var library := line.strip_edges().get_file().get_basename()
			if line.ends_with(".json") and not library in out:
				out.append(library)
	out.sort()
	return out


# Whether WHAT names a file under samples/ rather than an instrument id or a
# registry file.
func _is_sample_path(what: String) -> bool:
	var ext := what.get_extension().to_lower()
	return ext != "" and ext != "json"


# A samples path spelled the way Layer.take_key spells an SFZ:
# res://samples/<relative>.
func _sample_key(what: String) -> String:
	var rel := what.trim_prefix("res://").simplify_path()
	if not rel.begins_with("samples/"):
		rel = "samples/" + rel
	return "res://" + rel


func _plays_file(layer: SfzEnsemble.Layer, file: String) -> bool:
	if file == "":
		return false
	return layer.take_key == file or layer.sfz_path == file \
		or layer.cabinet_path == file


# Registry instruments with a layer on `file`, or a cabinet on it: one no
# ensemble plays yet is still concerned.
func _registry_files(file: String) -> Array:
	var out: Array = []
	for library in _libraries():
		var instruments: Dictionary = _registry(library).get("instruments", {})
		for key: String in instruments:
			var inst: Dictionary = instruments[key]
			var hit := inst.has("cabinet") and "res://samples/" + String(inst["cabinet"]) == file
			for layer: Dictionary in inst.get("layers", []):
				for field in ["sfz", "cabinet"]:
					if layer.has(field) and "res://samples/" + String(layer[field]) == file:
						hit = true
			if hit:
				out.append("%s/%s" % [library, key])
	return out


# The instruments of a registry file: all of them, or with `since` the ones
# whose JSON differs from that revision's, including any it has since lost.
func _changed_instruments(path: String, since: String) -> Array:
	var rel := path.trim_prefix("res://")
	var library := rel.get_file().get_basename()
	var now: Dictionary = _registry(library).get("instruments", {})
	var out: Array = []
	if since == "":
		for key: String in now:
			out.append("%s/%s" % [library, key])
		return out
	var git_out: Array = []
	var code := OS.execute("git", ["-C", ProjectSettings.globalize_path("res://"),
		"show", "%s:%s" % [since, rel]], git_out, true)
	var then: Dictionary = {}
	if code == 0:
		var old: Variant = JSON.parse_string(String(git_out[0]))
		if old is Dictionary:
			then = old.get("instruments", {})
	else:
		print("(%s has no %s; every instrument in it is new)" % [since, rel])
	for key: String in now:
		if not then.has(key) or JSON.stringify(then[key], "", true) \
				!= JSON.stringify(now[key], "", true):
			out.append("%s/%s" % [library, key])
	for key: String in then:
		if not now.has(key):
			out.append("%s/%s" % [library, key])
	return out


# The tests whose subject an instrument carries: `layers` for more than one
# layer or a release_cuts, `drums`, `bend` for a bend_range, `controls`.
func _fields_of(ids: Array) -> Array:
	var out: Array = []
	for id: String in ids:
		var split := id.split("/", true, 1)
		if split.size() != 2:
			continue
		var inst: Variant = _registry(split[0]).get("instruments", {}).get(split[1], null)
		if not inst is Dictionary:
			continue
		var text := JSON.stringify(inst)
		if (inst.get("layers", []) as Array).size() > 1 or "\"release_cuts\"" in text:
			out.append("layers")
		if inst.has("drums"):
			out.append("drums")
		if inst.has("bend_range"):
			out.append("bend")
		if "\"controls\"" in text:
			out.append("controls")
	return out


# The parts a score writes lanes for.
func _written_parts(score: SfzScore) -> Dictionary:
	var out := {}
	for section: SfzScore.Section in score.sections.values():
		for lane: SfzScore.Lane in section.lanes.values():
			out[lane.part] = true
	return out


# Registry files as plain JSON, read once each: --impact asks what a file
# says, not what an ensemble built from it would play.
var _registries := {}

func _registry(library: String) -> Dictionary:
	if not _registries.has(library):
		# A library deleted since --since is read as empty, not as an error:
		# its instruments are what the change lost.
		var path := SfzSettings.registry_path(library)
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) 			if FileAccess.file_exists(path) else null
		_registries[library] = data if data is Dictionary else {}
	return _registries[library]


func _libraries() -> Array:
	var dir := SfzSettings.registry_path("x").get_base_dir()
	var out: Array = []
	for f in DirAccess.get_files_at(dir):
		if (f as String).ends_with(".json"):
			out.append((f as String).get_basename())
	out.sort()
	return out


# --- Odds and ends ---------------------------------------------------------

func _score_ids() -> Array:
	var names := Array(DirAccess.get_files_at(SCORES)).filter(
		func(f: String) -> bool: return f.ends_with(".score"))
	names.sort()
	var ids := []
	for f in names:
		ids.append((f as String).get_basename())
	return ids


func _ensemble_ids() -> Array:
	var names := Array(DirAccess.get_files_at(ENSEMBLES)).filter(
		func(f: String) -> bool: return f.ends_with(".json"))
	names.sort()
	var ids := []
	for f in names:
		ids.append((f as String).get_basename())
	return ids


func _value(args: PackedStringArray, flag: String) -> String:
	var at := Array(args).find(flag)
	if at < 0 or at + 1 >= args.size():
		return ""
	return args[at + 1]
