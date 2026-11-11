extends Node

# Renders a score to a .wav so it can be listened to without launching Godot.
#
#   godot --headless --path . --audio-driver Dummy \
#       res://addons/sfzplayer/tools/render.tscn -- --score battle
#
# Two ways out of here, and the default is the fast one.
#
# The real-time path is the obvious one: an AudioEffectRecord on Master, the
# actual audio thread, the actual buses, one second of wall clock per second
# of music. It is the ground truth, and as a working loop it is unusable - a
# 105 second piece costs 105 seconds a take, and a mix decision is never one
# take.
#
# The offline path is the same music through the same arithmetic with the
# audio server taken out of the middle. It is deliberately not a second
# scheduler: the Conductor, the compiler, the layer rules and the compiled
# event list are the ones the game uses, and the only thing that changes is
# that each SfzInstrument hands its events to an OfflineRenderer instead of to
# a playback. The mix is not reimplemented either - Godot's own Reverb, EQ and
# AudioFilterSW are compiled from its sources into the extension, and the
# numbers come from SfzMixer.offline_bus/offline_master, which sit directly
# beneath the functions that build the buses so the two cannot quietly drift.
#
# `--compare` writes both, as -offline.wav and -realtime.wav, which is what
# keeps the paragraph above from being a claim nobody ever checks;
# tools/compare_takes.py is what reads them.
#
# Command line, after a bare `--`:
#   --ensemble   combo              (default: the score's own ensemble: header,
#                                or combo if it has none)
#   --score  battle             (a score id from the scores folder, or a path;
#                                default sealed-ward, the demo's)
#   --sections verse coda       (a shorter excerpt)
#   --play   literal            (default: performance)
#   --out    res://renders      (directory the files land in)
#   --gain   4                  (dB of extra gain on top of the score's
#                                loudness trim; default 0, the game's level)
#   --no-trim                   (leave out the score's trim from
#                                scores/loudness.json: the level as written)
#   --variants -3 0 3           (offline only: also write the same take
#                                through the master chain at each of these
#                                gains, as -g<gain>.wav beside it - one
#                                synthesis, several levels, for
#                                tools/loudness_fix.py)
#   --only   bass perc          (solo: mute every other bus; a part is
#                                heard or muted with the others on its bus)
#   --registry DIR              (instruments from this registry folder
#                                instead of sfzplayer/paths/registry)
#   --loops  3                  (a looping score's loop, this many times;
#                                default once, which is the piece as written)
#   --leave  bar 130            (loop until 130 s in, then leave at the next
#                                bar - or section, or pass - into the outro)
#   --intensity 2               (the level the piece plays at: lanes written
#                                layer:N come in from N; default 0)
#   --realtime                  (the audio server, at 1x)
#   --as-game                   (offline only: load only the articulations
#                                and keys the piece plays, as the game's
#                                MusicDirector does, into -as-game.wav; the
#                                same take as without it, or the filter
#                                left something out)
#   --compare                   (both of them, side by side)
#
# Two flags that make no sound at all, and quit before anything is loaded:
#   --show  [ensemble ...]          (what each ensemble's parts can play; no ensembles
#                                named means every ensemble on the roster)
#   --xref  [score ...]         (what a score uses that its ensemble does not
#                                map: events lost, counted, and controls it
#                                cannot shape, listed; no scores named means
#                                all of them)
#   --against cathedral combo   (with --xref: these ensembles instead of the
#                                score's own)
#   --matrix                    (with --xref: every named score against every
#                                ensemble, as a table of lost-event gap counts)
# tools/roster.py is the shell-out to those two. See _inspect().

const DEFAULT_SCORE := "sealed-ward"

# Long enough for the longest release on the roster to ring out past the last
# note, which is what the real-time path gets for free by waiting.
const TAIL := 2.0

# Below this a bus's peak is float dust, not sound: -120 dB.
const SILENT_PEAK := 1e-6

@onready var conductor: SfzConductor = $Conductor

var _score_path := DEFAULT_SCORE
var _ensembles: Array[String] = []
var _sections: Array[String] = []

# A contiguous slice of what plays, by section name, both ends inclusive. This
# is a different thing from `--sections`, which replaces the order outright:
# here the order is whatever the score says, repeats and all, and the render is
# a window onto it. Naming a section that repeats takes its first appearance
# for `--from` and its last for `--to`, so `--from litany --to litany` renders
# every litany in the piece rather than the first one twice.
#
# It exists because a section is seventeen seconds and the piece is a hundred
# and five, and most edits are to one section. Rendering the other five to hear
# the one is six times the wait for nothing: one section renders in 1.6 seconds
# against 8.6 for the piece.
#
# What a slice is not is the corresponding stretch of the full render. It is a
# valid performance of those sections - same notes, same instruments, same
# per-section seeds, because PerformanceCompiler seeds from the section name -
# but the libraries with round robins are at a different place in their
# rotation, because a round robin advances per note played and the notes before
# the slice were never played. Nulled against the full render, the section
# measured: keys, which has no round robins, 8.6 dB below signal, the residual
# being the reverb tail the slice never inherited; the guitar, which has eleven
# thousand seq_position opcodes, at signal level; the kit above it. So this is
# for deciding whether a section works, which is what iteration is, and the
# whole piece is what you render to decide whether it is finished.
var _from := ""
var _to := ""
var _reading := "performance"
var _out_dir := "res://renders"
var _realtime := false
var _compare := false
var _as_game := false

# Soloing is here rather than in the mixer because it is a measuring tool, not
# a mix control: balancing buses against each other means knowing what each
# one actually contributes to the file, and that is one render per bus with
# the rest muted. Muting the bus rather than dropping the events keeps every
# send, compressor and reverb tail exactly where it is in the full mix.
var _only: Array[String] = []

# Rendering the loop more than once is how a join is checked: the second pass
# has to sound like the first, and the seam between them like nothing.
var _loops := 1
var _leave_how := ""
var _leave_at := -1.0
var _intensity := 0

# Extra gain on top of the score's loudness trim (SfzLoudness). The trim is
# what the game plays at, so the default is 0: a render is what the player
# hears, at -16 LUFS. What follows is why this used to be 3.
#
# The mix leaves headroom on purpose - six buses, none of them allowed to
# clip when they all land on the same downbeat - so the raw game mix sits
# around -22 dBFS RMS. That is correct for a game, where the bus fader is the
# player's, and quiet for a file somebody is going to double click. This is
# applied to Master for the duration of the render and is reported with the
# file, so a quiet render is never a mystery.
#
# 3 dB is where the file lands at -18.9 dBFS RMS with the limiter catching
# peaks rather than riding the whole piece. It used to be 15, which was set
# when the buses were balanced by peak and the mix was much quieter; at 15 the
# limiter now holds hands with the signal for 96 seconds out of 105, which is
# not a safety net, it is the loudest thing in the arrangement. It came down
# from 4 when the guitar arrived: a sixth bus is a sixth of the energy the
# master chain has to swallow, and at 4 the limiter went from 25 seconds of
# the piece to 35.
var _gain_db := 0.0
var _trim := true
var _variants: Array[float] = []

# --show and --xref: the reading modes. See _inspect().
var _show: Array[String] = []
var _xref: Array[String] = []
var _xref_ensembles: Array[String] = []
var _xref_matrix := false

var _record: AudioEffectRecord
var _amplify: AudioEffectAmplify


func _ready() -> void:
	_read_args()

	# The reading modes make no sound and never open an SFZ: they read the
	# ensemble manifests with SfzEnsemble.load_from(path, false), which does not
	# require the sample tree to be on disk, and the scores. test_roster in
	# tools/run_tests.py runs --show in a copy of the project with no
	# samples/ folder to hold that. They are here
	# rather than in a Python script because SfzEnsemble and SfzScoreParser are
	# the readers the player itself uses, and a second reader would drift
	# from them the moment a manifest grew a field.
	if not _show.is_empty() or not _xref.is_empty():
		var code := _inspect()
		get_tree().quit(code)
		return

	if not _score_path.ends_with(".score"):
		_score_path = SfzSettings.score_path(_score_path)
	var score := SfzScoreParser.parse_file(_score_path)
	if score == null:
		push_error("render: %s did not parse" % _score_path)
		get_tree().quit(1)
		return
	if not _sections.is_empty():
		score.order = _sections
		score.clear_loop()
	if not _slice(score):
		get_tree().quit(1)
		return
	if _ensembles.is_empty():
		_ensembles = [score.ensemble_id if score.ensemble_id != "" else "combo"]

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir))

	print("\nrendering %s (\"%s\"), %.1fs per ensemble, %+.1f dB" % [
		_score_path.get_file(), score.title, score.duration(), _gain_db])
	if not _trim:
		print("  no loudness trim")

	for id in _ensembles:
		if _compare:
			await _render_offline(score, id, "-offline")
			await _render_realtime(score, id, "-realtime")
		elif _realtime:
			await _render_realtime(score, id, "")
		else:
			await _render_offline(score, id, "")

	print("midi event growths: %d" % SfzInstrument.get_midi_event_growths())
	print("\nrender done")
	get_tree().quit()


# Narrows score.order to the --from..--to window. Returns false if either name
# is not in the order, which is a typo rather than an empty render, and worth
# stopping for: headless Godot will happily render silence and say nothing.
func _slice(score: SfzScore) -> bool:
	if _from.is_empty() and _to.is_empty():
		return true

	var first := 0
	var last := score.order.size() - 1
	if not _from.is_empty():
		first = score.order.find(_from)
		if first < 0:
			push_error("render: --from %s is not in the order (%s)"
				% [_from, ", ".join(score.order)])
			return false
	if not _to.is_empty():
		last = score.order.rfind(_to)
		if last < 0:
			push_error("render: --to %s is not in the order (%s)"
				% [_to, ", ".join(score.order)])
			return false
	if last < first:
		push_error("render: --to %s comes before --from %s" % [_to, _from])
		return false

	score.order = score.order.slice(first, last + 1)
	score.clear_loop()
	return true


func _read_args() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		match args[i]:
			"--score":
				i += 1
				if i < args.size():
					_score_path = args[i]
			"--ensemble":
				i += 1
				if i < args.size():
					_ensembles = [args[i]]
			"--play":
				i += 1
				if i < args.size():
					_reading = args[i]
			"--out":
				i += 1
				if i < args.size():
					_out_dir = args[i]
			"--gain":
				i += 1
				if i < args.size():
					_gain_db = args[i].to_float()
			"--no-trim":
				_trim = false
			"--variants":
				# Negative numbers start with "-", never "--".
				i += 1
				while i < args.size() and not args[i].begins_with("--"):
					_variants.append(args[i].to_float())
					i += 1
				continue
			"--show":
				i += 1
				while i < args.size() and not args[i].begins_with("--"):
					_show.append(args[i])
					i += 1
				if _show.is_empty():
					_show = _all_ensembles()
				continue
			"--xref":
				i += 1
				while i < args.size() and not args[i].begins_with("--"):
					_xref.append(args[i])
					i += 1
				if _xref.is_empty():
					_xref = _all_scores()
				continue
			"--against":
				i += 1
				while i < args.size() and not args[i].begins_with("--"):
					_xref_ensembles.append(args[i])
					i += 1
				continue
			"--matrix":
				_xref_matrix = true
			"--realtime":
				_realtime = true
			"--compare":
				_compare = true
			"--as-game":
				_as_game = true
			"--only":
				i += 1
				while i < args.size() and not args[i].begins_with("--"):
					_only.append(args[i])
					i += 1
				continue
			"--from":
				i += 1
				if i < args.size():
					_from = args[i]
			"--to":
				i += 1
				if i < args.size():
					_to = args[i]
			"--registry":
				# Another registry folder for this run only (the project
				# setting is left as it is): the same score through other
				# copies of the instruments.
				i += 1
				if i < args.size():
					ProjectSettings.set_setting(SfzSettings.REGISTRY, args[i])
			"--loops":
				i += 1
				if i < args.size():
					_loops = maxi(args[i].to_int(), 1)
			"--leave":
				if i + 2 < args.size():
					_leave_how = args[i + 1]
					_leave_at = args[i + 2].to_float()
					i += 2
			"--intensity":
				i += 1
				if i < args.size():
					_intensity = maxi(args[i].to_int(), 0)
			"--sections":
				i += 1
				while i < args.size() and not args[i].begins_with("--"):
					_sections.append(args[i])
					i += 1
				continue
		i += 1


# --- Shared ----------------------------------------------------------------

func _path_for(score: SfzScore, id: String, suffix: String) -> String:
	var stem := "%s-%s" % [score.title.to_lower().replace(" ", "-"), id]
	if not _only.is_empty():
		stem += "-" + "-".join(_only)
	if _loops > 1 and score.has_loop() and _leave_at < 0.0:
		stem += "-x%d" % _loops
	if _intensity > 0:
		stem += "-i%d" % _intensity
	if _leave_at >= 0.0 and score.has_loop():
		stem += "-leave-%s-%d" % [_leave_how, roundi(_leave_at)]
	# In the name, so a slice never quietly overwrites the whole piece.
	if not _from.is_empty() or not _to.is_empty():
		stem += "-%s..%s" % [_from if not _from.is_empty() else "start",
			_to if not _to.is_empty() else "end"]
	if _as_game:
		stem += "-as-game"
	return "%s/%s%s.wav" % [_out_dir, stem, suffix]


# The score's loudness trim for this ensemble, unless --no-trim.
func _trim_db(score: SfzScore, id: String) -> float:
	return SfzLoudness.gain_db(score, id) if _trim else 0.0


func _muted(bus: String) -> bool:
	return not _only.is_empty() and not _only.has(bus)


# The loudest part on each bus, over `so_far`. There are six buses,
# and an ensemble need not have a part on every one: those read silent.
func _bus_peaks(ensemble: SfzEnsemble, stats: Dictionary, so_far: Dictionary) -> Dictionary:
	var out := {}
	for bus in SfzEnsemble.BUSES:
		out[bus] = float(so_far.get(bus, 0.0))
		for p: SfzEnsemble.Part in ensemble.parts_on(bus):
			if stats.has(p.name):
				out[bus] = maxf(out[bus], stats[p.name].peak)
	return out


# Per bus, not one number for the whole ensemble: a single peak is always the
# loudest bus's, which tells you nothing about the four underneath it. These
# are sfizz's own output peaks, before part gain and before any bus effect, so
# they say what each instrument actually delivers.
func _print_peaks(peaks: Dictionary) -> void:
	var report := PackedStringArray()
	for bus in SfzEnsemble.BUSES:
		var value: float = peaks.get(bus, 0.0)
		report.append("%s %s" % [bus,
			"silent" if value < SILENT_PEAK else "%+.1f dB" % (20.0 * (log(value) / log(10.0)))])
	print("  source peaks: %s" % ", ".join(report))


# --- Offline ---------------------------------------------------------------

func _render_offline(score: SfzScore, id: String, suffix: String) -> void:
	var ensemble := SfzEnsemble.load_from(SfzSettings.ensemble_path(id))
	if ensemble == null:
		return

	# Built before load_ensemble(), because load_ensemble() is what attaches the
	# layers to it - after that point the renderer already owns the synths.
	var renderer := SfzOfflineRenderer.new()
	renderer.configure(AudioServer.get_mix_rate())
	# Per bus, in BUSES order, whether any part plays through it or not: the
	# renderer's mix order is its bus order, and it is part of the sound.
	for bus in SfzEnsemble.BUSES:
		renderer.set_role_chain(bus, SfzMixer.offline_bus(bus,
				ensemble.buses.get(bus, {})))
		renderer.set_role_muted(bus, _muted(bus))
	var trim := _trim_db(score, id)
	renderer.set_master(SfzMixer.offline_master(_gain_db + trim))
	var path := _path_for(score, id, suffix)
	for g in _variants:
		renderer.add_master_variant(g + trim,
			ProjectSettings.globalize_path(path.get_basename() + "-g%s.wav" % _gain_name(g)))

	conductor.offline = renderer
	var articulations: Variant = null
	var played: Variant = null
	if _as_game:
		# Read as the take below reads it, or it plans a different piece.
		var planner := SfzScorePlayer.new(conductor)
		planner.compiler = SfzPerformanceCompiler.new() if _reading == "performance" else SfzScoreCompiler.new()
		planner.intensity = _intensity
		add_child(planner)
		await planner.prepare(score, ensemble)
		articulations = planner.articulations()
		played = planner.played()
		planner.queue_free()
	var loaded: bool = await conductor.load_ensemble(ensemble, articulations, played)
	if not loaded:
		conductor.offline = null
		return

	var player := SfzScorePlayer.new(conductor)
	player.compiler = SfzPerformanceCompiler.new() if _reading == "performance" else SfzScoreCompiler.new()
	add_child(player)
	player.loop_passes = 0 if _leave_at >= 0.0 else _loops
	player.intensity = _intensity
	# The game's own calls, in the game's order: play() uploads each layer's
	# timeline and sends PLAY, and leave_loop() decides the way out as it would
	# at --leave's moment, with the conductor's offline clock standing at it.
	# The conductor hands both to the renderer rather than to a playback, and
	# the timeline cursors in it play the piece as the audio thread would.
	conductor.offline_time = 0.0
	if not player.play(score):
		player.queue_free()
		conductor.unload()
		conductor.offline = null
		return
	if _leave_at >= 0.0 and score.has_loop():
		conductor.offline_time = _leave_at
		print("  asked to leave at %.1fs, left at %.2fs (%s)" % [
			_leave_at, player.leave_loop(_leave_how), _leave_how])
	# Where the music ends, as the player has decided it: the outro's end, or a
	# loop's after its --loops passes. A loop left nowhere has no end.
	var music := player.next_boundary("end", 0.0)
	if is_inf(music) or is_nan(music):
		push_error("%s: the piece has no end to render to" % id)
		player.queue_free()
		conductor.unload()
		conductor.offline = null
		return
	var events := player.event_count()
	print("\n%s: %d events, %s reading, offline%s" % [ensemble.id, events,
		player.compiler.describe(),
		"" if _only.is_empty() else ", solo %s" % ", ".join(_only)])
	# Where the joins fall in the file, for tools/seam_check.py: the loop's
	# start, each time it goes round again, and the way into the outro. The
	# file starts at the piece's top, so these are seconds into it.
	if score.has_loop() and _leave_at < 0.0:
		var joins := PackedStringArray()
		for k in range(1, _loops):
			joins.append("%.6f" % (score.loop_end() + (k - 1) * score.loop_length()))
		print("  loop seams: start %.6f, joins [%s], outro %.6f" % [
			float(score.timeline()[score.loop_from]["at"]), " ".join(joins),
			score.loop_end() + (_loops - 1) * score.loop_length()])

	var result: Dictionary = renderer.render(music + TAIL,
		ProjectSettings.globalize_path(path))
	conductor.offline_time = 0.0
	# Every timeline row on time, and every cursor done no sooner than the
	# player said the music ends and inside the file: anything else is the
	# cursor and the player disagreeing, or the file cutting rows off. A
	# cursor ends after its last row, so releases ringing past the written
	# end are expected. Rows the take or a layer delay moved ahead of the top
	# are expected too: PLAY is at frame 0 with no lead, so they go out at
	# frame 0, as the old scheduler clamped them.
	if int(result.get("late_emits", 0)) != 0 or int(result.get("starved_rows", 0)) != 0:
		push_error("%s: %d late, %d starved timeline rows" % [id,
			int(result.get("late_emits", 0)), int(result.get("starved_rows", 0))])
	if int(result.get("ahead_of_start", 0)) != 0:
		print("  %d rows ahead of the top, sent at it" % int(result.get("ahead_of_start", 0)))
	var ended := int(result.get("ended_frame", -1))
	var rate := float(renderer.get_sample_rate())
	if ended < 0 or ended / rate < music - 0.01 or ended / rate > music + TAIL:
		push_warning("%s: the timelines ended at %.3fs; the music ends at %.3fs and the file at %.3fs" % [
			id, ended / rate, music, music + TAIL])

	# One read at the end rather than one a frame: there are no frames here,
	# and take_peak() has been accumulating across the whole render.
	var peaks := _bus_peaks(ensemble, conductor.stats(), {})

	player.queue_free()
	conductor.unload()
	conductor.offline = null

	if result.is_empty():
		push_error("%s: the offline renderer produced nothing" % id)
		return

	var wall: float = maxf(result.wall_seconds, 0.001)
	print("  %s  %.1fs  in %.1fs (%.0fx real time)" % [
		path, result.seconds, result.wall_seconds, result.seconds / wall])
	print("  trim %+.1f dB (%s)" % [trim, "scores/loudness.json" if _trim else "off"])
	for v: Dictionary in result.get("variants", []):
		print("  variant %+.2f dB: %s" % [float(v.amplify_db) - trim, v.path])
	_print_peaks(peaks)


# A gain as a file name: -2.5 -> m2.5, 3 -> 3.
func _gain_name(g: float) -> String:
	return ("m" if g < 0.0 else "") + String.num(absf(g), 2)


# --- Real time -------------------------------------------------------------

func _render_realtime(score: SfzScore, id: String, suffix: String) -> void:
	var ensemble := SfzEnsemble.load_from(SfzSettings.ensemble_path(id))
	if ensemble == null:
		return

	# On the music bus, so the file is exactly what the speakers would have
	# had: it is the last bus with anything on it.
	#
	# The makeup gain is an effect rather than the bus volume because the
	# effect chain is processed before the fader: a recorder in the chain
	# never sees the bus's own volume, so setting it does nothing at all to
	# the file.
	#
	# It goes at the *head* of the music bus's chain, ahead of the EQ, the glue
	# compressor and the limiter, and the recorder goes at the tail. The
	# game mix is quiet enough that a master chain reading it raw would
	# barely open at all, so a render that boosted afterwards would capture
	# three effects doing nothing and then clip past the ceiling they were
	# there to hold. Boosting first means the file is the mix at a normal
	# level, which is the only level the master chain was tuned for.
	var music := SfzMixer.music_bus()
	SfzMixer.ensure(music)
	var index := AudioServer.get_bus_index(music)
	# The score's trim goes on the same bus when the player starts it
	# (SfzScorePlayer.play_at), as an effect of its own at the head; this
	# gain is the extra on top, so the two land in front of the chain
	# together, which is what the offline path's single amplify is.
	_amplify = AudioEffectAmplify.new()
	_amplify.volume_db = _gain_db
	AudioServer.add_bus_effect(index, _amplify, 0)
	_record = AudioEffectRecord.new()
	AudioServer.add_bus_effect(index, _record)

	if not await conductor.load_ensemble(ensemble):
		_strip_master()
		return

	for bus in SfzEnsemble.BUSES:
		var bus_index := AudioServer.get_bus_index(SfzMixer.bus_name(music, bus))
		if bus_index >= 0:
			AudioServer.set_bus_mute(bus_index, _muted(bus))

	var player := SfzScorePlayer.new(conductor)
	player.compiler = SfzPerformanceCompiler.new() if _reading == "performance" else SfzScoreCompiler.new()
	add_child(player)

	player.loop_passes = 0 if _leave_at >= 0.0 else _loops
	player.intensity = _intensity

	# Arm the recorder before play(), so the lead-in silence is captured and
	# the file starts where the piece starts rather than part way into it.
	_record.set_recording_active(true)
	player.play(score)
	if not _trim:
		SfzMixer.set_trim(music, 0.0)
	print("\n%s: %d events, %s reading, real time%s" % [ensemble.id,
		player.event_count(), player.compiler.describe(),
		"" if _only.is_empty() else ", solo %s" % ", ".join(_only)])

	var peaks := {}
	var left := false
	while player.is_playing():
		if not left and _leave_at >= 0.0 and player.position() >= _leave_at:
			left = true
			print("  left at %.2fs (%s)" % [player.leave_loop(_leave_how), _leave_how])
		peaks = _bus_peaks(ensemble, conductor.stats(), peaks)
		await get_tree().process_frame

	_record.set_recording_active(false)
	var wav := _record.get_recording()
	player.queue_free()
	conductor.unload()
	_strip_master()

	if wav == null:
		push_error("%s: the recorder produced nothing" % id)
		return

	var path := _path_for(score, id, suffix)
	var err := wav.save_to_wav(path)
	if err != OK:
		push_error("%s: could not write %s (error %d)" % [id, path, err])
		return

	var seconds := float(wav.data.size()) / (wav.mix_rate * (4.0 if wav.stereo else 2.0))
	print("  %s  %.1fs  %.1f MB" % [path, seconds, wav.data.size() / 1048576.0])
	_print_peaks(peaks)

	await get_tree().create_timer(0.5).timeout


# The recorder and the makeup gain go onto the music bus per take rather than once for
# the whole run, because under --compare an offline take happens in between and
# has no business being followed around by a recorder it never reaches.
#
# By identity rather than by position: the score's trim is at the head of the
# same bus, and stays.
func _strip_master() -> void:
	var index := AudioServer.get_bus_index(SfzMixer.music_bus())
	for e in range(AudioServer.get_bus_effect_count(index) - 1, -1, -1):
		var effect := AudioServer.get_bus_effect(index, e)
		if effect == _record or effect == _amplify:
			AudioServer.remove_bus_effect(index, e)


func _exit_tree() -> void:
	conductor.unload()


# --- Reading modes ---------------------------------------------------------
#
# `--show` and `--xref` answer the two questions that used to be answered by
# opening an ensemble's JSON and reading it, which is a manual step that scales
# badly and is wrong the moment a manifest grows a field.
#
#   --show                     every ensemble on the roster
#   --show tonewheel combo     these ensembles
#   --xref                     every score against its own ensemble
#   --xref sealed-ward         one score against its own ensemble
#   --xref sealed-ward --against cathedral
#   --xref --matrix            every score against every ensemble
#
# tools/roster.py is a two-line shell-out to these.

# The controls a score can actually cause to be sent are
# SfzPerformanceCompiler.SCORE_CONTROLS, named in full wherever this file
# means them. Every other control an ensemble maps is reachable only through a
# `defaults` block, never from a lane, so mapping them does not make an ensemble
# more expressive to a score. No constant here holds a copy or an alias of
# it: scripts/roster_test.gd fails if any script but the compiler's does.

# A part is expressive when a score can shape it in more than one way beyond
# what every part gets. Whether a part hears a control is SfzEnsemble.Part.hears(),
# the same call tools/check.gd makes, and under it every filled part hears
# `bend` (the pitch wheel). So bend is one of the count for every part, and
# the line is three heard controls: bend plus two of the part's own. It is
# deliberately low - a floor, not a grade.
const EXPRESSIVE_CONTROLS := 3

const NOTE_NAMES: Array[String] = ["C", "C#", "D", "D#", "E", "F", "F#",
	"G", "G#", "A", "A#", "B"]


func _inspect() -> int:
	var bad := 0
	for id in _show:
		if not _show_ensemble(id):
			bad = 1
	if not _xref.is_empty():
		if not _cross_reference():
			bad = 1
	return bad


func _all_ensembles() -> Array[String]:
	var dir := SfzSettings.ensemble_path("x").get_base_dir()
	var out: Array[String] = []
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".json"):
			out.append(f.get_basename())
	out.sort()
	return out


func _all_scores() -> Array[String]:
	var dir := SfzSettings.score_path("x").get_base_dir()
	var out: Array[String] = []
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".score"):
			out.append(f.get_basename())
	out.sort()
	return out


func _note_name(key: int) -> String:
	return "%s%d" % [NOTE_NAMES[posmod(key, 12)], key / 12 - 1]


# Every control this part answers to, part-wide or on any one layer, as
# name -> "cc" or "cc (layer)". The layer half matters: a part that maps
# nothing and whose layers map everything is expressive, and reading only
# part.controls would call it mute.
func _mapped_controls(part: SfzEnsemble.Part) -> Dictionary:
	var out := {}
	for name in part.controls:
		out[name] = str(int(part.controls[name]))
	for layer in part.layers:
		for name in (layer as SfzEnsemble.Layer).controls:
			var cc := str(int((layer as SfzEnsemble.Layer).controls[name]))
			if out.has(name) and out[name] == cc:
				continue
			out[name] = "%s on %s" % [cc, (layer as SfzEnsemble.Layer).name]
	return out


# Every articulation the part can be switched to, part-wide or per layer.
func _mapped_articulations(part: SfzEnsemble.Part) -> Array[String]:
	var out: Array[String] = []
	for name in part.keyswitches:
		if not out.has(name):
			out.append(name)
	for layer in part.layers:
		for name in (layer as SfzEnsemble.Layer).keyswitches:
			if not out.has(name):
				out.append(name)
	out.sort()
	return out


func _tier(part: SfzEnsemble.Part) -> String:
	if part.layers.is_empty():
		return "empty"
	var n := 0
	for name in SfzPerformanceCompiler.SCORE_CONTROLS:
		if part.hears(name):
			n += 1
	return "expressive" if n >= EXPRESSIVE_CONTROLS else "raw"


func _show_ensemble(id: String) -> bool:
	var ensemble := SfzEnsemble.load_from(SfzSettings.ensemble_path(id), false)
	if ensemble == null:
		print("show: ensemble %s did not load" % id)
		return false

	# "Buses filled" counts buses with a part on them: the six are the
	# mix's six, and a bus with two parts is one bus filled, not two.
	var expressive := 0
	var filled := 0
	for name in SfzEnsemble.BUSES:
		var on_bus := ensemble.parts_on(name)
		var any := false
		for r: SfzEnsemble.Part in on_bus:
			if r.layers.is_empty():
				continue
			any = true
			if _tier(r) == "expressive":
				expressive += 1
		if any:
			filled += 1

	print("")
	print("ensemble %s - %s" % [ensemble.id, ensemble.name])
	if ensemble.description != "":
		print("  %s" % ensemble.description)
	print("  %d of 6 buses filled, %d expressive" % [filled, expressive])

	var sources := {}
	for r2: SfzEnsemble.Part in ensemble.attach_order():
		if r2.layers.is_empty():
			continue
		if r2.gain_source != "":
			sources[r2.gain_source] = int(sources.get(r2.gain_source, 0)) + 1
		for layer in r2.layers:
			var s: String = (layer as SfzEnsemble.Layer).gain_source
			if s != "":
				sources[s] = int(sources.get(s, 0)) + 1
	var parts: Array[String] = []
	for s in SfzEnsemble.GAIN_SOURCES:
		parts.append("%d %s" % [int(sources.get(s, 0)), s])
	print("  gains: %s" % ", ".join(parts))

	var shown: Array = []
	for name in SfzEnsemble.BUSES:
		if ensemble.parts_on(name).is_empty():
			shown.append(name)
		else:
			shown.append_array(ensemble.parts_on(name))
	for entry in shown:
		# A bus nothing plays through, by its name.
		if entry is String:
			print("")
			print("  %-7s empty - notes written for it go nowhere" % entry)
			continue
		var part: SfzEnsemble.Part = entry
		var name := part.name
		if part.layers.is_empty():
			print("")
			print("  %-7s empty - notes written for it go nowhere" % name)
			continue
		print("")
		print("  %-7s %-10s keys %s-%s (%d-%d)  voices %d  gain %+.1f dB (%s)" % [
			name, _tier(part), _note_name(part.lokey), _note_name(part.hikey),
			part.lokey, part.hikey, part.voices, part.gain_db,
			part.gain_source if part.gain_source != "" else "not set"])
		# A part named for its family on the bus of that name is the common
		# case; anything else is worth a line.
		if part.family != name or part.bus != name:
			print("            family %s, bus %s" % [part.family, part.bus])
		for layer in part.layers:
			var l := layer as SfzEnsemble.Layer
			var extra := ""
			if l.instrument != "":
				extra += "  %s" % l.instrument
			if l.transpose != 0:
				extra += "  transpose %+d" % l.transpose
			if l.lovel != 0 or l.hivel != 127:
				extra += "  vel %d-%d" % [l.lovel, l.hivel]
			if l.delay != 0.0:
				extra += "  delay %.3fs" % l.delay
			print("            layer %-22s %+5.1f dB %-10s voices %-3d  %s%s" % [
				l.name, l.gain_db,
				"" if l.gain_source == "" else "(%s)" % l.gain_source,
				l.voices, l.sfz_path.get_file(), extra])
		var controls := _mapped_controls(part)
		var keys := controls.keys()
		keys.sort()
		var scored: Array[String] = []
		var other: Array[String] = []
		for c in keys:
			var text := "%s:%s" % [c, controls[c]]
			if c in SfzPerformanceCompiler.SCORE_CONTROLS:
				scored.append(text)
			else:
				other.append(text)
		# Bend with no CC of its own is still heard, on the pitch wheel
		# (SfzEnsemble.Part.hears), and counts toward the tier, so it is listed.
		if not controls.has("bend") and part.hears("bend"):
			scored.append("bend:wheel")
		print("            controls a score can reach (%d/%d): %s" % [
			scored.size(), SfzPerformanceCompiler.SCORE_CONTROLS.size(),
			", ".join(scored) if not scored.is_empty() else "none"])
		if not other.is_empty():
			print("            other controls (%d): %s" % [
				other.size(), ", ".join(other)])
		var arts := _mapped_articulations(part)
		if not arts.is_empty():
			var d := " (default %s)" % part.keyswitch_default 				if part.keyswitch_default != "" else ""
			print("            articulations (%d): %s%s" % [
				arts.size(), ", ".join(arts), d])
		if not part.drums.is_empty():
			var drums := part.drums.keys()
			drums.sort()
			print("            drums (%d): %s" % [drums.size(), ", ".join(drums)])
	return true


# --- Score vs ensemble ---------------------------------------------------------
#
# What a score asks for that an ensemble has no answer to. Every one of these is
# silent at runtime by design - a kit with no ride drops the ride rather than
# failing - which is right for a game and wrong for the person writing the
# score, who finds out by rendering ninety seconds and listening.
#
# `sealed-ward` is the case that motivated this: it asks for the drum
# `snare_dry` and the articulation `marcato`, and each of those exists in two
# of the ten ensembles. Nothing in the system said so.


# What one score asks of one of its parts. Gathered from the score alone, so
# it is gathered once and then measured against as many ensembles as you like.
class PartNeeds extends RefCounted:
	var notes := 0
	var lokey := 127
	var hikey := 0
	var arts := {}      # articulation -> lanes that ask for it
	var drums := {}     # drum name -> times hit
	var controls := {}  # control name -> what in the score asks for it


# Score part -> PartNeeds, in the score's order of parts.
func _needs_of(score: SfzScore) -> Dictionary:
	var found := {}
	for section_name in score.sections:
		var section: SfzScore.Section = score.sections[section_name]
		for lane_name in section.lanes:
			var lane: SfzScore.Lane = section.lanes[lane_name]
			if not found.has(lane.part):
				found[lane.part] = PartNeeds.new()
			var n: PartNeeds = found[lane.part]
			if lane.art != "":
				n.arts[lane.art] = int(n.arts.get(lane.art, 0)) + 1
			# Every lane is given a dynamic, written or not, so every lane
			# wants the dynamics control.
			n.controls["dynamics"] = "every lane"
			if lane.vib != "" and lane.vib != "none":
				n.controls["vibrato_depth"] = "vib:%s" % lane.vib
			if lane.rot != "":
				n.controls["rotary"] = "rot:%s" % lane.rot
			for e in lane.events:
				var event := e as SfzScore.Event
				if event.drum != "":
					n.drums[event.drum] = int(n.drums.get(event.drum, 0)) + 1
				for key in event.keys:
					n.notes += 1
					n.lokey = mini(n.lokey, key)
					n.hikey = maxi(n.hikey, key)
				if event.slur:
					n.controls["legato_attack"] = "a slurred note"
					n.controls["sustain"] = "a slurred note"
				if event.slide:
					n.controls["interval_a"] = "a slide"
				if event.scoop:
					n.controls["interval_b"] = "a scoop"
	var out := {}
	for part_name in score.parts:
		if found.has(part_name):
			out[part_name] = found[part_name]
	return out


# What the score uses that the ensemble does not map, in two lists:
#
#   "lost"   events the compiler sends and nothing plays: a part the ensemble
#            casts on nothing, an unmapped drum, a lane articulation
#            (emitted unconditionally at the top of
#            SfzPerformanceCompiler._lane). These are the gaps, and the only
#            thing counted -
#            the same losses tools/check.gd counts by compiling the score and
#            walking its events, so the two tools agree on a pairing.
#   "notes"  what the score asks for that the ensemble cannot shape, where no
#            event is ever sent: every control is written behind
#            has_control() in SfzPerformanceCompiler, so an unmapped one
#            costs expression but loses nothing; and notes folded by octaves
#            into the sampled range still sound.
#
# Each score part is asked of the ensemble part SfzEnsemble.cast plays it on - the
# resolution the player uses - and a part cast on nothing comes first,
# because it makes every other line about that part moot.
func _gaps(needs: Dictionary, ensemble: SfzEnsemble, score_parts: Dictionary) -> Dictionary:
	var out: Array[String] = []
	var notes: Array[String] = []
	var cast := ensemble.cast(score_parts)
	for part_name: String in needs:
		var n: PartNeeds = needs[part_name]
		var part := ensemble.part(cast.get(part_name, {"part": part_name})["part"])
		if part.layers.is_empty():
			out.append("%s: nothing in this ensemble plays it - %d notes and %d drum hits go nowhere"
				% [part_name, n.notes, _total(n.drums)])
			continue

		var drums := n.drums.keys()
		drums.sort()
		for drum in drums:
			if part.key_for(drum) < 0:
				out.append("%s: drum '%s' unmapped - %d hits are silent"
					% [part_name, drum, n.drums[drum]])

		var arts := n.arts.keys()
		arts.sort()
		var mapped_arts := _mapped_articulations(part)
		for art in arts:
			if art in mapped_arts:
				continue
			var note := "the part keeps whatever it was last switched to"
			if part.keyswitch_default != "":
				note = "falls back to '%s'" % part.keyswitch_default
			out.append("%s: articulation '%s' unmapped - %d lanes ask for it, %s"
				% [part_name, art, n.arts[art], note])

		for control in SfzPerformanceCompiler.SCORE_CONTROLS:
			if not n.controls.has(control):
				continue
			if part.hears(control):
				continue
			# legato_attack and sustain are alternatives to each other in the
			# performance compiler: either one carries a slur.
			if control == "legato_attack" and part.hears("sustain"):
				continue
			if control == "sustain" and part.hears("legato_attack"):
				continue
			notes.append("%s: control '%s' unmapped - %s asks for it; never sent, so nothing is lost"
				% [part_name, control, n.controls[control]])

		if n.notes > 0 and (n.lokey < part.lokey or n.hikey > part.hikey):
			notes.append("%s: written %s-%s, sampled %s-%s - notes outside are folded by octaves"
				% [part_name, _note_name(n.lokey), _note_name(n.hikey),
				_note_name(part.lokey), _note_name(part.hikey)])
	return {"lost": out, "notes": notes}


func _total(counts: Dictionary) -> int:
	var n := 0
	for k in counts:
		n += int(counts[k])
	return n


func _cross_reference() -> bool:
	var ok := true
	var ensembles := {}
	var wanted: Array[String] = _xref_ensembles.duplicate()
	if _xref_matrix:
		wanted = _all_ensembles()
	for id in wanted:
		var b := SfzEnsemble.load_from(SfzSettings.ensemble_path(id), false)
		if b == null:
			print("xref: ensemble %s did not load" % id)
			ok = false
			continue
		ensembles[id] = b

	var matrix := {}
	for score_id in _xref:
		var path := score_id if score_id.ends_with(".score") else SfzSettings.score_path(score_id)
		var score := SfzScoreParser.parse_file(path)
		if score == null:
			print("xref: %s did not parse" % score_id)
			ok = false
			continue
		var own := score.ensemble_id if score.ensemble_id != "" else "combo"
		var needs := _needs_of(score)

		var against: Array[String] = []
		if not ensembles.is_empty():
			for k in ensembles:
				against.append(String(k))
			against.sort()
		else:
			var b2 := SfzEnsemble.load_from(SfzSettings.ensemble_path(own), false)
			if b2 == null:
				print("xref: %s: ensemble %s did not load" % [score_id, own])
				ok = false
				continue
			ensembles[own] = b2
			against = [own]

		var row := {}
		for ensemble_id in against:
			var found := _gaps(needs, ensembles[ensemble_id], score.parts)
			var gaps: Array[String] = found["lost"]
			var notes: Array[String] = found["notes"]
			row[ensemble_id] = gaps.size()
			if _xref_matrix and ensemble_id != own:
				continue
			print("")
			print("%s -> %s%s: %d gap%s, %d note%s" % [score_id, ensemble_id,
				" (its own ensemble)" if ensemble_id == own else "",
				gaps.size(), "" if gaps.size() == 1 else "s",
				notes.size(), "" if notes.size() == 1 else "s"])
			for line in gaps:
				print("    lost: %s" % line)
			for line in notes:
				print("    note: %s" % line)
		matrix[score_id] = {"own": own, "row": row}

	if _xref_matrix:
		_print_matrix(matrix, _all_ensembles())
	return ok


# Gaps per score per ensemble. Scores are ensemble-portable by design, so "what
# breaks if I move this piece to that ensemble" is a real question, and the
# answer is a number per cell rather than a yes or a no. `.` is a clean
# move; a number is that many names whose events would be lost (see _gaps:
# what cannot be shaped but loses nothing is not counted).
func _print_matrix(matrix: Dictionary, ensemble_ids: Array[String]) -> void:
	print("")
	print("gap matrix - rows are scores, columns ensembles, * marks the score's own ensemble")
	var header := "%-22s" % ""
	for id in ensemble_ids:
		header += " %-6s" % id.substr(0, 5)
	print(header)
	var names := matrix.keys()
	names.sort()
	for score_id in names:
		var row: Dictionary = matrix[score_id]["row"]
		var own: String = matrix[score_id]["own"]
		var line := "%-22s" % score_id
		for id in ensemble_ids:
			var n := int(row.get(id, -1))
			var cell := "-" if n < 0 else ("." if n == 0 else str(n))
			if id == own:
				cell += "*"
			line += " %-6s" % cell
		print(line)
