class_name SfzConductor
extends Node

# Owns the players an ensemble needs, and gives everything above it one clock to
# write to.
#
# "The players an ensemble needs" is not five. A part may be several instruments
# at once - see SfzEnsemble.Layer - so this builds one SfzInstrument per layer and
# addresses a part by fanning out across its stack. Everything here speaks in
# the ensemble's parts; which of them plays a score's part is the cast's
# question (SfzEnsemble.cast), answered above this line by SfzScorePlayer.
#
# The clock is the interesting part. Each SfzInstrument counts frames from
# its own _start(), so five instruments mean five clocks that agree on the
# rate but not on zero. They do not drift, though: AudioServer mixes every
# playback in a single pass, so each clock advances by the same frame count
# at the same moment, and the difference between any two of them is a
# constant. Measure that constant once, at load, and every later conversion
# is exact - no resampling, no periodic resync, no accumulating error.
#
# Times passed to note()/cc()/hit() are therefore on one timeline: seconds
# since the ensemble finished loading, read with now().

signal ensemble_ready(ensemble: SfzEnsemble)

# Anything scheduled less than this far ahead is at the mercy of the next
# mix block. It is not the audio latency - it is how much slack the game
# thread gets before the audio thread has already passed the moment.
const MIN_LEAD := 0.05

# On top of MIN_LEAD and the driver's own latency: one game frame at a bad
# frame rate, so a stutter while the piece starts does not cost the downbeat.
const LEAD_MARGIN := 0.05

# A player that never reports a clock is a player that never started; give
# up rather than hang the scene.
const START_TIMEOUT := 2.0

# An ensemble's parse, all layers at once, in the background. The largest on the
# roster takes about sixteen seconds on this machine; a load that has not
# finished in this long is a library that is not coming.
const LOAD_TIMEOUT := 120.0

# What unload() let go of is gone in a few mix steps and a reaper pass; a
# slot that is still not freed after this long is loaded over anyway.
const FREE_TIMEOUT := 2.0

var ensemble: SfzEnsemble

# Where the five players end up. Each one actually plays into its own
# bus - Mixer builds those, with the reverb and compression that bus wants -
# and those buses all send here. Two Conductors on two destinations is how
# one area's music fades out while the next is already loading; set it
# before load_ensemble(), since the players and their buses are built there.
# Left empty it is the music bus itself (SfzMixer.music_bus()).
var bus: StringName = &""

# part -> Array of { layer, player, instrument, offset, keyswitches }, in manifest order,
# built in SfzEnsemble.attach_order(). The offset is per instrument rather than
# per part, because each playback counts frames from its own _start().
# Set before load_ensemble() to build the ensemble against an offline render instead
# of the audio server. Everything below this line then behaves the same way -
# the same fold, the same layer rules, the same scheduled times - because the
# only thing that changes is where an SfzInstrument sends its events. That is
# the whole point of the seam: an offline take is not a second scheduler with
# a second set of bugs, it is this one, without the wait.
var offline: SfzOfflineRenderer = null

# now() offline, in seconds: there is no mix to count, so the render sets the
# clock itself - to the moment a decision is made at (tools/render.gd sets it
# to --leave's time before leave_loop()), exactly as the game makes it at
# now() live. Everything else offline is placed by frame and never reads it.
var offline_time := 0.0

var _stacks: Dictionary = {}
var _reference: SfzInstrument = null
# Every score timeline uploaded to this ensemble's instruments and not yet
# ended: SfzScorePlayer's records, {entry, slot, voice, player (weakref), part,
# ended}. See claim_timeline().
var _timelines: Array = []
# True when the instruments could not agree on a shared frame count at load
# (set_reference() never reported an offset): ops then carry each
# instrument's own frames, from the offsets _measure_offsets() reads.
var _local_frames := false
var _warned: Dictionary = {}       # "part/control" -> true, so we nag once
var _loaded := false
# The instruments unload() let go of, until freed() has seen the last of them.
var _dying: Array[SfzInstrument] = []

# What went wrong on the way to the instruments since load_ensemble(), for stats()
# and for the once-per-conductor warnings (see _watch()): events moved later
# because they were already too late to schedule, per part; events the queues
# had no room for, summed over the ensemble; and the process-wide starved-voice
# count as it stood at load, which later readings are taken from.
var _clamped: Dictionary = {}
var _dropped_seen := 0
# Presses note_on() moved later, [part, key, written time] -> seconds
# moved, until note_off() moves the release with them.
var _moved: Dictionary = {}
var _starved_at_load := 0

# heard(): heard game time minus conductor time, as of the game frame
# _heard_frame, and heard(now()) at that anchor, which the next may not go
# below. See _anchor_heard().
var _heard_offset := 0.0
var _heard_frame := -1
var _heard_last := -INF


func is_loaded() -> bool:
	return _loaded


# How far ahead of now() the first event of a piece should be placed. The
# driver's own latency is the part that actually matters and it is different
# on every machine, so it is asked for rather than guessed at.
func lead() -> float:
	if offline != null:
		return 0.0
	return AudioServer.get_output_latency() + MIN_LEAD + LEAD_MARGIN


# Seconds on the shared clock. Schedule for now() + some lead.
func now() -> float:
	if not _loaded:
		return 0.0
	if offline != null:
		return offline_time
	return _reference.get_playback_time()


# Frames per second of every timeline frame on this conductor: the offline
# render's own rate when there is one (what it was configured with, which is
# what its synths run at), else the audio server's.
func rate() -> float:
	if offline != null:
		return float((offline as Object).call("get_sample_rate"))
	return AudioServer.get_mix_rate()


# Offline there is no driver and no mix block to miss, so nothing needs to be
# placed ahead of anything; every event already has an absolute time.
func is_offline() -> bool:
	return offline != null


# `at`, or now() + lead() when `at` is already too close to be scheduled
# where it asks: the earliest moment a direct event can be heard where it is
# sent. A late event is played late rather than at the head of whatever block
# the audio thread is on, which is where the scheduler would put it; either
# way it is not where it was asked for, and it is counted per part in stats()
# and warned about once per conductor.
#
# Late means earlier than now() + lead() less LEAD_MARGIN. That margin is the
# game thread's own slack: a score player lays its downbeat at now() + lead()
# and sends it a frame later, when now() has moved on, and that downbeat is not
# late - MIN_LEAD is still between it and the mix. Offline nothing is late.
# A negative `at` is the scheduler's "now" and is left alone.
func _on_time(part_name: String, at: float) -> float:
	if at < 0.0 or offline != null or not _loaded:
		return at
	var earliest := now() + lead()
	if at >= earliest - LEAD_MARGIN:
		return at
	_clamped[part_name] = int(_clamped.get(part_name, 0)) + 1
	if not _warned.has("!late"):
		_warned["!late"] = true
		push_warning("conductor: %s event at %.3f s is %.0f ms late for ensemble %s; moved to now() + lead(), and every late event after it is counted in stats() without another word" % [
			part_name, at, (earliest - at) * 1000.0, ensemble.id])
	return earliest


# Reads the queues and the disk stream, and warns once per conductor about
# each that has lost something since load: events dropped because a queue was
# full, and voices sfizz cut short because their samples had not arrived. Each
# frame, and from stats(). The starved count is sfizz's own and covers every
# instrument in the process, not just this ensemble's, so every conductor loaded
# at the time sees it.
func _watch() -> void:
	if not _loaded:
		return
	var dropped := 0
	for part_name in _stacks:
		for entry in _stacks[part_name]:
			dropped += (entry.instrument as SfzInstrument).get_dropped_events()
	if dropped > _dropped_seen:
		_dropped_seen = dropped
		if not _warned.has("!dropped"):
			_warned["!dropped"] = true
			push_warning("conductor: ensemble %s dropped %d events, a queue being full; see stats() for the count by part" % [
				ensemble.id, dropped])
	var starved := _starved_voices() - _starved_at_load
	if starved > 0 and not _warned.has("!starved"):
		_warned["!starved"] = true
		push_warning("conductor: %d voices cut short waiting on the disk while ensemble %s is loaded; see stats()" % [
			starved, ensemble.id])


# True on the main thread. Everything a game calls on the conductor and the
# player is main-thread only: events go to the audio thread through a queue
# with one writer (SfzInstrumentPlayback::push_event, native/src/
# sfz_instrument.cpp, reads and then stores write_pos with no lock), and a
# second thread writing to it corrupts it rather than failing. So a call from
# any other thread is refused with an error instead: the event is not sent,
# nothing changes. Two engine calls each time.
static func _on_main(what: String) -> bool:
	if OS.get_thread_caller_id() == OS.get_main_thread_id():
		return true
	push_error("%s: called off the main thread, and refused; the public API is main-thread only" % what)
	return false

# sfizz's process-wide count of voices cut short for want of samples.
func _starved_voices() -> int:
	return SfzInstrument.get_starved_voices()


func _process(_delta: float) -> void:
	_watch()
	_poll_timelines()


# The game time - Time.get_ticks_usec() / 1e6, what _process reads - at which
# conductor time `t` reaches the output: a beat's flash, a hit's camera shake,
# put on the frame the sound is heard rather than the frame it was sent.
#
# now() counts frames mixed, and a frame is mixed well before it is heard: it
# was mixed in the audio server's last step, get_time_since_last_mix() ago,
# and it then waits get_output_latency() in the driver's buffers. So the
# conductor sample at now() was mixed at game time (game - since) and is heard
# that plus the latency; every other sample is its distance from now() either
# side of that. What the driver reports as its latency is what this can know:
# a driver that under-reports it, and the Dummy driver the tests run on, which
# reports none, make heard() early by what is missing.
#
# Re-anchored once per game frame, so every call in a frame agrees, and
# heard(now()) never goes backwards from one frame to the next. It is read
# against the audio server's own last mix rather than against this ensemble's
# clock alone, so when this conductor stops mixing - SfzMusicDirector.pause()
# disables it, and every clock under the director stops with it - the map
# moves on with the game, and after resume() it is right again at once rather
# than out by the length of the pause.
#
# Offline there is no output and no game time: `t` comes back as it went in,
# seconds into the file. NAN with no ensemble loaded.
func heard(t: float) -> float:
	if not _loaded:
		return NAN
	if offline != null:
		return t
	var frame := Engine.get_process_frames()
	if frame != _heard_frame:
		_heard_frame = frame
		_anchor_heard()
	return t + _heard_offset


# One clean reading of the three clocks: the frames this ensemble has mixed, the
# game clock, and how long ago the audio server last mixed. Between two mix
# steps, like _measure_offsets: an even, unchanged epoch either side and a
# `since` that did not go backwards (a new step would have reset it) mean all
# three describe the same step.
func _anchor_heard() -> void:
	var latency := AudioServer.get_output_latency()
	var offset := NAN
	var mixed := 0.0
	for _attempt in CLOCK_READ_TRIES:
		var before: int = SfzInstrument.get_mix_epoch()
		if before % 2 == 1:
			continue
		var since := AudioServer.get_time_since_last_mix()
		var game := Time.get_ticks_usec() / 1e6
		mixed = _reference.get_playback_time()
		if SfzInstrument.get_mix_epoch() != before \
				or AudioServer.get_time_since_last_mix() < since:
			continue
		offset = game - since + latency - mixed
		break
	if is_nan(offset):
		AudioServer.lock()
		var since_locked := AudioServer.get_time_since_last_mix()
		var game_locked := Time.get_ticks_usec() / 1e6
		mixed = _reference.get_playback_time()
		AudioServer.unlock()
		offset = game_locked - since_locked + latency - mixed
	# The step the reading lands next to is scheduled a little early or late
	# by the audio thread, so the offset wobbles by a fraction of a block from
	# frame to frame. Downwards, that could put what is heard now before what
	# was heard a frame ago; that much is held.
	if mixed + offset < _heard_last:
		offset = _heard_last - mixed
	_heard_last = mixed + offset
	_heard_offset = offset


# Builds a player per layer, waits for all of them to be mixing, measures the
# clock offsets, then applies the ensemble's default controls. Awaits; the
# ensemble_ready signal fires on success.
#
# `articulations` (ensemble part -> Array of names, as
# SfzScorePlayer.articulations() gives them) loads only the samples those
# articulations and each part's keyswitch_default play. A guitar library
# holds forty articulations and a piece plays two or three, so this is most
# of the memory and most of the load. A part it leaves out plays only its
# default. null loads every articulation, for a caller that cannot know what
# it will ask for; see covers() for whether a load will do for another piece.
#
# `played` (ensemble part -> {"keys", "drums"}, as SfzScorePlayer.played()
# gives them) does the same for the keys: each layer loads only the samples
# those notes and drums press on it, with its keyswitches. A kit played on
# four of its forty keys loads four. A part it leaves out loads everything,
# as does null.
func load_ensemble(new_ensemble: SfzEnsemble, articulations: Variant = null,
		played: Variant = null) -> bool:
	if not SfzConductor._on_main("SfzConductor.load_ensemble"):
		return false
	unload()
	# The old ensemble's memory back before the new one's is asked for, or the
	# two are resident together for as long as the load takes.
	await freed()
	if new_ensemble == null:
		return false
	ensemble = new_ensemble
	if offline == null:
		if bus == &"":
			bus = SfzMixer.music_bus()
		SfzMixer.ensure(bus)
		SfzMixer.apply_ensemble(bus, ensemble)

	# Bus by bus in BUSES order, then manifest order: the offline renderer
	# counts the voices attached under each bus, and sfizz's seeds come from
	# that count, so the order is part of the sound (SfzEnsemble.attach_order).
	for part: SfzEnsemble.Part in ensemble.attach_order():
		var stack: Array = []
		var arts: Variant = null
		if articulations != null:
			arts = (articulations as Dictionary).get(part.name, [])
		var plays: Variant = null
		if played != null:
			plays = (played as Dictionary).get(part.name)
		for layer: SfzEnsemble.Layer in part.layers:
			var entry := _attach(part, layer, arts, plays)
			if entry.is_empty():
				unload()
				return false
			stack.append(entry)
		_stacks[part.name] = stack

	# Offsets exist because five playbacks each count frames from their own
	# _start(). Offline there is one clock and every event carries an absolute
	# time, so they are all zero and there is nothing to wait for.
	if offline == null:
		if not await _wait_for_parse():
			push_error("Conductor: ensemble '%s' did not finish loading in %.0f s" % [
				ensemble.id, LOAD_TIMEOUT])
			unload()
			return false
		if not await _wait_for_clocks():
			push_error("Conductor: ensemble '%s' never started mixing" % ensemble.id)
			unload()
			return false
		await _share_reference()
		if ensemble != new_ensemble:
			return false   # unloaded, or another load, while it waited
	else:
		_reference = _first_instrument()
		_local_frames = false
	_apply_defaults()
	_clamped = {}
	_moved = {}
	_dropped_seen = 0
	_starved_at_load = _starved_voices()
	_loaded = true
	ensemble_ready.emit(ensemble)
	return true


# One layer's instrument, made and attached: to a player of its own on the
# part's bus, or to the offline render under the part's bus. Returns its stack
# entry, or {} when the offline render would not take it. Every instrument
# load_ensemble() makes is made here, and every call that reaches one after that
# goes through _press, _lift, _tap, _send_cc or _send_wheel, so a conductor
# that overrides those six hears all that this one sends an instrument, in
# order, with no instrument at all (scripts/golden_test.gd --dest).
func _attach(part: SfzEnsemble.Part, layer: SfzEnsemble.Layer, arts: Variant,
		plays: Variant = null) -> Dictionary:
	var instrument := SfzInstrument.new()
	instrument.sfz_path = layer.sfz_path
	var keyswitches := _keyswitches(part, layer, arts)
	instrument.keyswitches = keyswitches
	var notes := _notes(part, layer, plays, keyswitches)
	instrument.notes = notes
	instrument.cabinet_path = layer.cabinet_path
	instrument.max_voices = layer.voices
	# The same preload offline as live. This used to ask for every
	# sample whole - 1 << 28 frames, which is more than any file has,
	# so sfizz held all of them - on the theory that a render at many
	# times real time asks the loading thread for many times the
	# samples per second, and a file that is entirely resident cannot
	# arrive late.
	#
	# That cost 31 seconds of every render. The guitar patch alone
	# names 2635 samples totalling 2.72 GB, and its two layers are two
	# synths with two file pools, so ensemble load read the same 2.72 GB
	# twice to play about thirty notes out of it: 40 seconds of
	# loading in front of 23 seconds of rendering.
	#
	# It was also not buying what it was paying for. Two renders of
	# this score with everything resident differ from each other by
	# 0.62 full scale; with the small preload they differ by 0.48. The
	# render is not reproducible either way, and the preload size is
	# not why - sfizz waits for background loading at the *top* of
	# renderBlock, so a note starting inside a block queues its read
	# and is not waited for until the next one, and its file garbage
	# collection fires off the wall clock. Both are still open. The
	# resident preload was a very expensive way of not fixing them.
	instrument.preload_frames = SfzSettings.preload_frames(layer.preload_frames)

	# Both trims, because they answer different questions: the part's
	# is where the part sits in the band, the layer's is how much of
	# this timbre is in the part.
	var gain_db: float = part.gain_db + layer.gain_db

	var player: AudioStreamPlayer = null
	if offline == null:
		player = AudioStreamPlayer.new()
		player.name = "%s_%s_%s" % [ensemble.id, part.bus, layer.name]
		player.stream = instrument
		player.volume_db = gain_db
		# The whole stack shares the part's bus, so a doubling sits
		# inside the part's own reverb rather than beside it.
		player.bus = SfzMixer.bus_name(bus, part.bus)
		add_child(player)
	elif not instrument.attach_offline(offline, part.bus, gain_db):
		push_error("Conductor: %s/%s did not load offline" % [
			part.name, layer.name])
		return {}

	var entry := {
		"layer": layer,
		"player": player,
		"instrument": instrument,
		"offset": 0.0,
		"keyswitches": keyswitches,
		"notes": notes,
		# Its voice in the offline render, which the render's timeline calls
		# name it by; -1 live. Untyped: an older native build has no such call.
		"voice": (instrument as Object).call("get_offline_voice") if offline != null else -1,
	}
	# play() starts the SFZ parse on a thread of its own and returns
	# at once, so every layer of the ensemble loads at the same time and
	# the game thread pays for none of it. Offline it was parsed by
	# attach_offline(), which is on this thread and does not matter.
	if player != null:
		player.play()
	return entry


# The keys `layer` is loaded for: those of `arts` and the part's default, as
# articulate() would press them. Empty, which loads every articulation, for
# no `arts` - or for a layer that answers none of them, which has nothing to
# leave out that a tap could ever reach.
func _keyswitches(part: SfzEnsemble.Part, layer: SfzEnsemble.Layer, arts: Variant) -> PackedInt32Array:
	var keys := PackedInt32Array()
	if arts == null:
		return keys
	var names: Array = (arts as Array).duplicate()
	if part.keyswitch_default != "":
		names.append(part.keyswitch_default)
	for articulation: String in names:
		var key := layer.keyswitch(articulation, part.keyswitch(articulation))
		if key >= 0 and not keys.has(key):
			keys.append(key)
	return keys


# The keys `layer` is loaded for: those `plays` (one part of what
# load_ensemble() takes as `played`) presses on it, as note() and hit() would,
# and its `keyswitches`, which may be notes too. Empty, which loads every key,
# for no `plays`.
func _notes(part: SfzEnsemble.Part, layer: SfzEnsemble.Layer, plays: Variant,
		keyswitches: PackedInt32Array) -> PackedInt32Array:
	var keys := PackedInt32Array()
	if plays == null:
		return keys
	for key: int in (plays as Dictionary).get("keys", []):
		var pitch := clampi(part.fit(key) + layer.transpose, 0, 127)
		if not keys.has(pitch):
			keys.append(pitch)
	for drum: String in (plays as Dictionary).get("drums", []):
		var key := part.key_for(drum)
		if key >= 0 and not keys.has(key):
			keys.append(key)
	for key: int in keyswitches:
		if not keys.has(key):
			keys.append(key)
	# Empty only when nothing reaches this layer: then it loads everything,
	# which costs memory but is never silent.
	return keys


# Whether what is loaded plays every articulation in `articulations` and every
# key in `played` (as load_ensemble() takes them): a preloaded ensemble can only
# stand in for a fresh load if nothing the new piece switches to or presses
# was left out of it.
func covers(articulations: Dictionary, played: Dictionary = {}) -> bool:
	if not _loaded:
		return false
	for part_name: String in played:
		var part := ensemble.part(part_name)
		for entry in _stacks.get(part_name, []):
			var loaded: PackedInt32Array = entry.notes
			if loaded.is_empty():
				continue
			for key: int in _notes(part, entry.layer, played[part_name], PackedInt32Array()):
				if not loaded.has(key):
					return false
	for part_name: String in articulations:
		var part := ensemble.part(part_name)
		for entry in _stacks.get(part_name, []):
			var loaded: PackedInt32Array = entry.keyswitches
			if loaded.is_empty():
				continue
			for articulation: String in articulations[part_name]:
				var key := (entry.layer as SfzEnsemble.Layer).keyswitch(articulation,
					part.keyswitch(articulation))
				if key >= 0 and not loaded.has(key):
					return false
	return true


# Lets go of the ensemble. Its memory goes later - the players at the end of
# the frame, their playbacks when the audio server next drops them, the synths
# on SfzInstrument's reaper thread - and freed() is how to wait for that.
func unload() -> void:
	if not SfzConductor._on_main("SfzConductor.unload"):
		return
	for part_name in _stacks:
		for entry in _stacks[part_name]:
			var player: AudioStreamPlayer = entry.player
			if player == null:
				continue
			player.stop()
			player.queue_free()
			_dying.append(entry.instrument)
	_stacks.clear()
	# A held slot unloaded is not held: the next ensemble's players start
	# mixing as they are added.
	process_mode = PROCESS_MODE_INHERIT
	_warned.clear()
	_moved.clear()
	_heard_frame = -1
	_heard_last = -INF
	_reference = null
	# The instruments go with their timelines: nothing is left to report.
	for record: Dictionary in _timelines:
		record["ended"] = true
	_timelines = []
	_local_frames = false
	_loaded = false
	ensemble = null


# Awaits until everything unload() let go of has been freed: no playback of
# its instruments left alive and nothing on the reaper - then hands the freed
# heap back to the system, which a crossfade's worth of samples otherwise
# stays counted against the game long after it is gone. Returns at once with
# nothing unloaded since the last call.
func freed() -> void:
	if _dying.is_empty():
		return
	var deadline := Time.get_ticks_msec() + int(FREE_TIMEOUT * 1000.0)
	while Time.get_ticks_msec() < deadline and not _all_freed():
		await get_tree().process_frame
	if _dying.is_empty():
		return   # another caller saw it through
	_dying.clear()
	SfzInstrument.trim_heap()


# A playback is destroyed before its instrument stops answering is_ready(), and
# its synth is on the reaper by then (SfzInstrumentPlayback's destructor), so
# the two together leave nothing between them.
func _all_freed() -> bool:
	for instrument in _dying:
		if instrument.is_ready():
			return false
	return SfzInstrument.get_pending_frees() == 0


# A loaded ensemble nothing plays yet - a director's preloaded slot - still
# costs a render of silence every block, most of a core on a small machine.
# Held, its players are stream-paused: the audio server skips them, sfizz
# renders nothing, and every clock of the ensemble stops. All in one mix step,
# with the audio server locked, so the clocks stop on the same frame and the
# offsets measured at load still hold when release() starts them together.
# Disabling the conductor is what pauses them, as SfzMusicDirector.pause()
# does the whole director; a pause and resume of the director above leaves a
# held slot held.
func hold() -> void:
	if not _loaded or offline != null or process_mode == PROCESS_MODE_DISABLED:
		return
	AudioServer.lock()
	process_mode = PROCESS_MODE_DISABLED
	AudioServer.unlock()


# Starts a held ensemble's clocks again, on one frame. now() stood still while
# it was held, so schedule against it only after this.
func release() -> void:
	if process_mode != PROCESS_MODE_DISABLED:
		return
	AudioServer.lock()
	process_mode = PROCESS_MODE_INHERIT
	AudioServer.unlock()


func is_held() -> bool:
	return process_mode == PROCESS_MODE_DISABLED


# --- Playing -------------------------------------------------------------

# One note, folded into the part's real range, held for `duration`, played by
# every layer that wants a note that hard.
#
# `part_name` is one of the ensemble's parts. A name it does not have is cast
# as a score's would be, by family (SfzEnsemble.resolve), so a game written
# against the six base families still reaches an ensemble whose parts are
# named otherwise.
#
# The fold happens once, against the part, so the stack agrees about which
# octave the part is in before any layer transposes off it. A layer's delay
# moves its copy of the note, release and all. A layer that is its own take
# (SfzEnsemble.Layer.take_offset) moves each note by its own amount and picks it a
# little harder or softer; the release moves with the note, so the take's
# note is as long as the written one. The velocity window is judged on the
# written velocity, so a take never swaps which layers play a note.
#
# `exact` plays the note where and as hard as it is written: no take offset
# and no take velocity, for a stinger that must land on a cue or a hit timed
# to a frame. The rest is the ensemble's and still applies - the fold, each
# layer's transpose, its velocity window and its fixed delay. A note played
# in halves must be exact in both, or the release lands off the press.
#
# `take_at` is the moment the take is read at, when that is not `at`. A take
# is a function of time, and of which time matters: SfzScorePlayer passes the
# note's time in the piece, so a piece takes the same way wherever it is
# placed on this clock, live or offline. A game's own note leaves it out and
# the take reads this clock.
func note(part_name: String, key: int, velocity: int, at: float, duration: float,
		exact: bool = false, take_at: float = NAN) -> void:
	if not SfzConductor._on_main("SfzConductor.note"):
		return
	part_name = _part_named(part_name)
	var part := ensemble.part(part_name)
	var folded := part.fit(key)
	var take := at if is_nan(take_at) else take_at
	at = _on_time(part_name, at)
	for entry in _stacks.get(part_name, []):
		var layer: SfzEnsemble.Layer = entry.layer
		if not layer.takes(velocity):
			continue
		var pitch := clampi(folded + layer.transpose, 0, 127)
		_check_loaded(entry, part_name, pitch)
		var t: float = at + entry.offset + layer.delay + (0.0 if exact else layer.take_offset(take))
		var played := clampi(velocity + (0 if exact else layer.take_velocity_offset(take)), 1, 127)
		_press(entry, pitch, played, t)
		_lift(entry, pitch, t + duration)


# The same note in two halves, for a player that may have to let go early.
# The release is worked out exactly as note() does it - the same layers, the
# same take offset read off the press - so a note played in halves sounds
# identical to one played whole, until the release is moved. `take_at` as for
# note(), and the same in both halves.
func note_on(part_name: String, key: int, velocity: int, at: float,
		exact: bool = false, take_at: float = NAN) -> void:
	if not SfzConductor._on_main("SfzConductor.note_on"):
		return
	part_name = _part_named(part_name)
	var part := ensemble.part(part_name)
	var folded := part.fit(key)
	var take := at if is_nan(take_at) else take_at
	var written := at
	at = _on_time(part_name, at)
	if at != written:
		_moved[[part_name, key, written]] = at - written
	for entry in _stacks.get(part_name, []):
		var layer: SfzEnsemble.Layer = entry.layer
		if not layer.takes(velocity):
			continue
		var pitch := clampi(folded + layer.transpose, 0, 127)
		_check_loaded(entry, part_name, pitch)
		var t: float = at + entry.offset + layer.delay + (0.0 if exact else layer.take_offset(take))
		var played := clampi(velocity + (0 if exact else layer.take_velocity_offset(take)), 1, 127)
		_press(entry, pitch, played, t)


# `at` is when the note was pressed as written, not when it is let go. A press
# note_on() moved later, being late, takes its release with it, as note()
# does, so the note keeps its length and the move is counted once. A release
# still too late after that is let go at now() + lead(), as a late press is
# played then, and counted.
func note_off(part_name: String, key: int, velocity: int, at: float,
		duration: float, exact: bool = false,
		take_at: float = NAN) -> void:
	if not SfzConductor._on_main("SfzConductor.note_off"):
		return
	part_name = _part_named(part_name)
	var part := ensemble.part(part_name)
	var folded := part.fit(key)
	var take := at if is_nan(take_at) else take_at
	var pressed := [part_name, key, at]
	if _moved.has(pressed):
		at += float(_moved[pressed])
		_moved.erase(pressed)
	if at >= 0.0:
		duration = _on_time(part_name, at + duration) - at
	for entry in _stacks.get(part_name, []):
		var layer: SfzEnsemble.Layer = entry.layer
		if not layer.takes(velocity):
			continue
		var pitch := clampi(folded + layer.transpose, 0, 127)
		var t: float = at + entry.offset + layer.delay + (0.0 if exact else layer.take_offset(take))
		_lift(entry, pitch, t + duration)


# A drum by name. Does nothing if this kit has no such piece, which is the
# whole point: body percussion has no ride, and a score that asks for one
# should thin out rather than fail. Nothing is not silence, though: a game
# calling this directly is told once per conductor per drum, never per hit.
# A score's hits were already reported at prepare (SfzScorePlayer
# ._report) and do not get here. `exact` and `take_at` as for note().
func hit(part_name: String, drum: String, velocity: int, at: float,
		exact: bool = false, take_at: float = NAN) -> void:
	if not SfzConductor._on_main("SfzConductor.hit"):
		return
	part_name = _part_named(part_name)
	var part := ensemble.part(part_name)
	var key := part.key_for(drum)
	var take := at if is_nan(take_at) else take_at
	if key < 0:
		var tag := "%s/hit:%s" % [part_name, drum]
		if not part.layers.is_empty() and not _warned.has(tag):
			_warned[tag] = true
			push_warning("conductor: %s has no '%s' in ensemble %s; those hits sit out" % [
				part_name, drum, ensemble.id])
		return
	at = _on_time(part_name, at)
	# Layer by layer, so a doubling kit that maps kick and snare and nothing
	# else simply sits out the hi-hats - the correct answer rather than a gap.
	# Transpose is ignored here: a drum key is a name in a map rather than a
	# pitch, and moving it would fetch a different instrument.
	for entry in _stacks.get(part_name, []):
		var layer: SfzEnsemble.Layer = entry.layer
		if not layer.takes(velocity):
			continue
		# The same take offsets a pitched note gets. Without them a
		# doubled kit puts both layers on the identical sample, which is
		# the one thing a second layer exists not to do, and the whole kit
		# lands on the grid to the sample - a drum machine playing a score
		# that has been written for a drummer everywhere else.
		_check_loaded(entry, part_name, key)
		var t: float = at + entry.offset + layer.delay + (0.0 if exact else layer.take_offset(take))
		var played := clampi(velocity + (0 if exact else layer.take_velocity_offset(take)), 1, 127)
		_press(entry, key, played, t)
		# A drum key is a one-shot: the note off is a formality that frees
		# the voice, so it trails the note on rather than the grid.
		_lift(entry, key, t + 0.05)


# A named control, 0..127. Unmapped controls are dropped with one warning -
# a score should be free to write vibrato for every part and let the ensembles
# that can hear it respond.
# A negative `at` means "now", matching the scheduler's own convention; it
# is how the ensemble's own defaults go out, so they never count as late.
func cc(part_name: String, control: String, value: int, at: float = -1.0) -> void:
	if not SfzConductor._on_main("SfzConductor.cc"):
		return
	part_name = _part_named(part_name)
	var part := ensemble.part(part_name)
	var number := part.cc(control)
	at = _on_time(part_name, at)
	if number < 0 and control == "bend":
		# No control of its own: the SFZ's pitch wheel plays the same bend,
		# as far as the wheel goes.
		var wheel := SfzScoreCompiler.wheel_value(value, part.bend_range)
		for entry in _stacks.get(part_name, []):
			var when: float = at if at < 0.0 else at + entry.offset
			_send_wheel(entry, wheel, when)
		return
	# A layer may read the control on a number of its own, so the stack is
	# asked one at a time rather than once for the part. The part's number
	# standing at -1 no longer means nobody hears it: a layer can name one
	# where the part names none, and only a stack where none of them does is
	# worth a warning.
	var heard := false
	for entry in _stacks.get(part_name, []):
		var on: int = (entry.layer as SfzEnsemble.Layer).cc(control, number)
		if on < 0:
			continue
		heard = true
		var when: float = at if at < 0.0 else at + entry.offset
		_send_cc(entry, on, clampi(value, 0, 127), when)
	if heard:
		return
	var tag := "%s/%s" % [part_name, control]
	if not _warned.has(tag):
		_warned[tag] = true
		print("conductor: %s has no '%s'; ignoring" % [part_name, control])


# Selects an articulation by tapping its keyswitch. Held briefly rather than
# pulsed, because sfizz latches on sw_last and a zero-length tap is a race.
#
# The tap goes to the whole stack, and each layer is tapped on the key it
# actually answers to: the part's, or its own where a layer names them - see
# SfzEnsemble.Layer.keyswitches. A stack drawn from one library shares the part's
# keys and says nothing; a stack drawn from several cannot, because a key
# that switches one instrument is a note on another. A layer with no key for
# this articulation is left alone, still playing the last one it was given,
# which is the quiet outcome; sending it the part's key would put an audible
# low note in the middle of the section instead.
#
# An articulation load_ensemble() was not given has no samples to switch
# to: that is an error, said once, and the layer plays on in the last one.
func articulate(part_name: String, articulation: String, at: float = -1.0) -> void:
	if not SfzConductor._on_main("SfzConductor.articulate"):
		return
	part_name = _part_named(part_name)
	var fallback := ensemble.part(part_name).keyswitch(articulation)
	at = _on_time(part_name, at)
	for entry in _stacks.get(part_name, []):
		var key: int = (entry.layer as SfzEnsemble.Layer).keyswitch(articulation, fallback)
		if key < 0:
			continue
		var loaded: PackedInt32Array = entry.keyswitches
		if not loaded.is_empty() and not loaded.has(key):
			var tag := "%s/art:%s" % [part_name, articulation]
			if not _warned.has(tag):
				_warned[tag] = true
				push_error("Conductor: %s was loaded without '%s'; load_ensemble() was not told it would be played" % [
					part_name, articulation])
			continue
		_tap(entry, key, at)


# A key load_ensemble() was not given has no samples to play: that is an
# error, said once per part and key. It is still pressed, as every other key
# is, so the instrument hears what it would have heard.
func _check_loaded(entry: Dictionary, part_name: String, key: int) -> void:
	var loaded: PackedInt32Array = entry.notes
	if loaded.is_empty() or loaded.has(key):
		return
	var tag := "%s/key:%d" % [part_name, key]
	if not _warned.has(tag):
		_warned[tag] = true
		push_error("Conductor: %s was loaded without key %d; load_ensemble() was not told it would be played" % [
			part_name, key])


# One keyswitch tap on one player: now for a negative `at`, else held from
# `at` on this clock for 0.02 s.
func _tap(entry: Dictionary, key: int, at: float) -> void:
	var instrument: SfzInstrument = entry.instrument
	if at < 0.0:
		instrument.note_on(key, 100)
		instrument.note_off(key, 0)
		return
	var t: float = at + entry.offset
	instrument.schedule_note_on(key, 100, t)
	instrument.schedule_note_off(key, 0, t + 0.02)


# Where every note and hit above reaches its instrument: `t` on this clock,
# with the entry's offset and the layer's delay and take already in it.
func _press(entry: Dictionary, pitch: int, velocity: int, t: float) -> void:
	(entry.instrument as SfzInstrument).schedule_note_on(pitch, velocity, t)


func _lift(entry: Dictionary, pitch: int, t: float) -> void:
	(entry.instrument as SfzInstrument).schedule_note_off(pitch, 0, t)


# Where every control and bend reaches its instrument, the ensemble's defaults at
# load among them: `when` on this clock with the entry's offset in it, or
# negative for now. Called untyped, as cc() always called them, so a test's
# stand-in for an instrument still receives them.
func _send_cc(entry: Dictionary, number: int, value: int, when: float) -> void:
	entry.instrument.schedule_cc(number, value, when)


func _send_wheel(entry: Dictionary, value: int, when: float) -> void:
	entry.instrument.schedule_pitch_wheel(value, when)


# --- Score timelines -------------------------------------------------------
#
# A score player hands each layer its whole piece (SfzTimeline, interface A in
# native/src/timeline.h) and then only decides: these are the calls it makes,
# and the conductor owns the slots, the clocks and the reports. The native
# calls are made untyped, so this script still loads against a native build
# that does not have them yet.

# `timeline` uploaded to a free slot of `entry`'s instrument for `player`, the
# score part `part_name` names in errors. Returns the record every later call
# takes, or {} when every slot is busy or the upload is refused (an error is
# pushed either way). A key the timeline presses that load_ensemble() was not
# given is an error, once, as a direct note() is; a keyswitch it was not
# given is left out, as articulate() would have had nothing to switch to.
func claim_timeline(player: Object, entry: Dictionary, timeline: Dictionary,
		part_name: String) -> Dictionary:
	var slot := -1
	for candidate in SfzTimeline.SLOTS:
		var taken := false
		for record: Dictionary in _timelines:
			if is_same(record["entry"]["instrument"], entry.instrument) \
					and record["slot"] == candidate:
				taken = true
				break
		if not taken:
			slot = candidate
			break
	if slot < 0:
		push_error("Conductor: %s has no free timeline slot; the piece is not played on it" % part_name)
		return {}
	for key: int in timeline.get("keys", PackedInt32Array()):
		_check_loaded(entry, part_name, key)
	var loaded: PackedInt32Array = entry.keyswitches
	if not loaded.is_empty():
		var missing := PackedInt32Array()
		for key: int in timeline.get("ks_keys", PackedInt32Array()):
			if not loaded.has(key):
				missing.append(key)
		if not missing.is_empty():
			timeline = _without_keyswitches(timeline, missing)
	var ok: bool
	if offline != null:
		ok = (offline as Object).call("attach_timeline", entry.voice, slot, timeline)
	else:
		ok = (entry.instrument as Object).call("upload_timeline", slot, timeline)
	if not ok:
		return {}
	var record := {"entry": entry, "slot": slot, "voice": entry.voice,
		"player": weakref(player), "part": part_name, "ended": false}
	_timelines.append(record)
	return record


# One decision (SfzTimeline.OP_*) to a record's cursor: `b` and `when` as
# timeline.h's interface B has them, `arg` the extra word.
func decide_timeline(record: Dictionary, op: int, b: int, when: int, arg: int = 0) -> bool:
	if record["ended"]:
		return false
	if offline != null:
		return (offline as Object).call("decide", record["voice"], op, record["slot"], b, when, arg)
	return (record["entry"]["instrument"] as Object).call("decide", op, record["slot"], b, when, arg)


# Conductor time `t` as the frame a PLAY for `record` is sent at: a frame of
# the shared count, or, when the instruments never agreed on one, of the
# record's own instrument's.
func timeline_frame(record: Dictionary, t: float) -> int:
	var frames_per_second := rate()
	if offline == null and _local_frames:
		return roundi((t + float(record["entry"]["offset"])) * frames_per_second)
	return roundi(t * frames_per_second)


# What a record's cursor last said of itself (interface C); {} offline.
func timeline_state(record: Dictionary) -> Dictionary:
	if offline != null or record["ended"]:
		return {}
	return (record["entry"]["instrument"] as Object).call("timeline_state", record["slot"])


# A record that never got its PLAY, given back: its slot free at once.
func forget_timeline(record: Dictionary) -> void:
	if record["ended"]:
		return
	record["ended"] = true
	_timelines.erase(record)
	if offline == null:
		(record["entry"]["instrument"] as Object).call("drop_timeline", record["slot"])


# Every cursor's reports since the last frame, to the player that owns it;
# a cursor that has ended gives its slot back.
func _poll_timelines() -> void:
	if _timelines.is_empty():
		return
	for record: Dictionary in _timelines.duplicate():
		var reports: PackedInt64Array
		if offline != null:
			reports = (offline as Object).call("poll_timeline", record["voice"], record["slot"])
		else:
			reports = (record["entry"]["instrument"] as Object).call("poll_timeline", record["slot"])
		var player: Object = (record["player"] as WeakRef).get_ref()
		for i in range(0, reports.size() - 2, 3):
			var kind := int(reports[i])
			if kind == SfzTimeline.REPORT_STARVED and not _warned.has("!timeline_starved"):
				_warned["!timeline_starved"] = true
				push_warning("conductor: a score timeline on %s ran out of time to commit its next pass; see stats()" % record["part"])
			if kind == SfzTimeline.REPORT_ENDED:
				record["ended"] = true
			if player != null:
				player.call("_timeline_report", record, kind, int(reports[i + 1]), int(reports[i + 2]))
		if record["ended"]:
			_timelines.erase(record)
			if offline == null:
				(record["entry"]["instrument"] as Object).call("drop_timeline", record["slot"])


# `timeline` without the rows that tap the keyswitches in `missing`: a copy,
# the original left as the plan has it.
static func _without_keyswitches(timeline: Dictionary, missing: PackedInt32Array) -> Dictionary:
	var out := timeline.duplicate()
	out["head"] = _segment_without(timeline["head"], missing)
	out["tail"] = _segment_without(timeline["tail"], missing)
	var bodies: Array = []
	for body: Dictionary in timeline["bodies"]:
		bodies.append(_segment_without(body, missing))
	out["bodies"] = bodies
	return out


static func _segment_without(segment: Dictionary, missing: PackedInt32Array) -> Dictionary:
	var ks: PackedByteArray = segment["ks"]
	var a: PackedByteArray = segment["a"]
	var keep := PackedInt32Array()
	for i in ks.size():
		if ks[i] == 0 or not missing.has(a[i]):
			keep.append(i)
	if keep.size() == ks.size():
		return segment
	var out := {}
	for column: String in segment:
		var source: Variant = segment[column]
		var copy: Variant = source.duplicate()
		copy.resize(keep.size())
		for j in keep.size():
			copy[j] = source[keep[j]]
		out[column] = copy
	return out


# The ensemble part a call names: `part_name` where it is one of this
# ensemble's, else what a score's part of that name would be cast on
# (SfzEnsemble.resolve) - "" for nothing, which reaches no player.
#
# Nothing is not silence here either. A family this ensemble has no part for is
# a warning, once per name per ensemble, as a score's part cast on nothing is at
# prepare. A name that is neither a part of this ensemble nor a family can only
# be a typo, and is an error, once: before parts it was a script error on the
# ensemble's dictionary, and it should not have got quieter.
func _part_named(part_name: String) -> String:
	if ensemble.parts.has(part_name):
		return part_name
	var family := part_name if SfzEnsemble.FAMILIES.has(part_name) else ""
	var found: String = ensemble.resolve(part_name, family)["part"]
	var tag := "!part/%s" % part_name
	if found == "" and not _warned.has(tag):
		_warned[tag] = true
		if family == "":
			push_error("conductor: part '%s' is not in ensemble %s, and not a family (%s); its events are not played" % [
				part_name, ensemble.id, ", ".join(SfzEnsemble.FAMILIES.keys())])
		else:
			push_warning("conductor: part '%s' (%s): not in ensemble %s; nothing plays it, and its events are not played" % [
				part_name, family, ensemble.id])
	return found


# The part's first layer - the one a reader would call the instrument.
func instrument(part_name: String) -> SfzInstrument:
	var stack: Array = _stacks.get(part_name, [])
	return stack[0].instrument if not stack.is_empty() else null


# Every instrument in a part, for anything that has to reach past its first.
func instruments(part_name: String) -> Array:
	var out: Array = []
	for entry in _stacks.get(part_name, []):
		out.append(entry.instrument)
	return out


# Everything the tests and the mixer want to see, per part. A stack reports
# as one part: counts add up, the worst timing error and the loudest peak
# win, and the offset is the first layer's, since that is the clock the part
# is scheduled against. take_peak() is a read-and-reset, so every layer has to
# be asked even when its answer loses.
#
# `dropped` is events a full queue refused, since load. `clamped` is events
# sent too late and moved to now() + lead() (_on_time()), since load.
# `starved` is voices sfizz cut short waiting on the disk since load, and it
# is the same number in every row: sfizz counts it for the whole process, so
# it is not this part's or even this ensemble's alone. Reading this also runs the
# warnings in _watch().
func stats() -> Dictionary:
	_watch()
	var out := {}
	var starved := _starved_voices() - _starved_at_load if _loaded else 0
	for part_name in _stacks:
		var stack: Array = _stacks[part_name]
		var row := {
			"regions": 0, "voices": 0, "late_frames": 0, "dropped": 0,
			"subframe": 0, "peak": 0.0, "preloaded": 0, "layers": stack.size(),
			"offset": stack[0].offset if not stack.is_empty() else 0.0,
			"clamped": int(_clamped.get(part_name, 0)), "starved": starved,
		}
		for entry in stack:
			var instrument: SfzInstrument = entry.instrument
			row.regions += instrument.get_region_count()
			row.voices += instrument.get_active_voices()
			row.dropped += instrument.get_dropped_events()
			row.subframe += instrument.get_subframe_placements()
			row.late_frames = maxi(row.late_frames, instrument.get_max_timing_error())
			row.peak = maxf(row.peak, instrument.take_peak())
			row.preloaded += instrument.get_preloaded_sample_count()
		out[part_name] = row
	return out


# How much preloaded sample audio - the heads of the files - this ensemble is
# holding in memory, in bytes. Layers loading the same files share one copy of
# each (sfizz-shared-samples.patch) and each counts its share, so the two slots
# of a director add up to what is held once, not once per ensemble. sfizz's
# per-region bookkeeping and the streamed files of playing notes are not
# counted (SfzInstrument.get_streamed_bytes() is the second), so the real
# figure is higher.
func memory_estimate() -> int:
	var total := 0
	for part_name in _stacks:
		for entry in _stacks[part_name]:
			total += entry.instrument.get_sample_bytes()
	return total


# --- Loading internals ---------------------------------------------------

# Every layer's parse, on its own thread; a frame at a time here, so the game
# and any music already playing carry on meanwhile.
func _wait_for_parse() -> bool:
	var deadline := Time.get_ticks_msec() + int(LOAD_TIMEOUT * 1000.0)
	while Time.get_ticks_msec() < deadline:
		var all_ready := true
		for part_name in _stacks:
			for entry in _stacks[part_name]:
				if not entry.instrument.is_ready():
					all_ready = false
					break
			if not all_ready:
				break
		if all_ready:
			return true
		await get_tree().process_frame
	return false


# A clock still reading zero means that playback has not been mixed yet, so
# the difference to any other clock is not yet meaningful.
func _wait_for_clocks() -> bool:
	var deadline := Time.get_ticks_msec() + int(START_TIMEOUT * 1000.0)
	while Time.get_ticks_msec() < deadline:
		var all_running := true
		for part_name in _stacks:
			for entry in _stacks[part_name]:
				if entry.instrument.get_playback_time() <= 0.0:
					all_running = false
					break
			if not all_running:
				break
		if all_running:
			return true
		await get_tree().process_frame
	return false


# The clock every other part is measured against: the first part, in attach
# order, that has anything in it, since a part may be empty.
func _first_instrument() -> SfzInstrument:
	for part_name in _stacks:
		if not _stacks[part_name].is_empty():
			return _stacks[part_name][0].instrument
	return null


# Read once, with the audio server locked. The differences are constant, but
# a mix step advances the playbacks one after another, and a read that lands
# part way through one sees some of them a block ahead of the rest - a layer
# a block out of time with its part. Locked, no step is part way through.
# See SfzMusicDirector.CLOCK_READ_TRIES.
const CLOCK_READ_TRIES := 64


# Every instrument told to count frames as the reference does (interface D in
# native/src/timeline.h), and each entry's offset read back from it: ops
# then carry one frame count for the whole ensemble. Instruments that never
# report one in START_TIMEOUT fall back to _measure_offsets() and their own
# counts (risk R1), with a warning.
func _share_reference() -> void:
	_reference = _first_instrument()
	_local_frames = false
	var others: Array = []
	for part_name in _stacks:
		for entry in _stacks[part_name]:
			(entry.instrument as Object).call("set_reference", _reference)
			if not is_same(entry.instrument, _reference):
				others.append(entry)
			else:
				entry.offset = 0.0
	var deadline := Time.get_ticks_msec() + int(START_TIMEOUT * 1000.0)
	var known := false
	while true:
		known = true
		for entry: Dictionary in others:
			if not (entry.instrument as Object).call("has_reference_offset"):
				known = false
				break
		if known or Time.get_ticks_msec() >= deadline or not is_inside_tree():
			break
		await get_tree().process_frame
	if known:
		var rate := AudioServer.get_mix_rate()
		for entry: Dictionary in others:
			entry.offset = -float((entry.instrument as Object).call("get_reference_offset")) / rate
		return
	push_warning("conductor: ensemble %s's instruments never shared a frame count; measuring offsets instead" % ensemble.id)
	for part_name in _stacks:
		for entry in _stacks[part_name]:
			(entry.instrument as Object).call("set_reference", null)
	_measure_offsets()
	_local_frames = true


# The fallback for _share_reference() (risk R1), and how every offset was read
# before it: each instrument's clock against the first, read between mix
# steps.
func _measure_offsets() -> void:
	_reference = _first_instrument()
	# Between two mix steps rather than holding one off - see the same read in
	# SfzMusicDirector._clock_offset for why the lock was costing 14-64 ms.
	# Offsets are written only once a whole pass reads clean, so a pass that
	# is interrupted part way leaves the previous values untouched.
	for _attempt in CLOCK_READ_TRIES:
		var before: int = SfzInstrument.get_mix_epoch()
		if before % 2 == 1:
			continue
		var base: float = _reference.get_playback_time()
		var read: Array = []
		for part_name in _stacks:
			for entry in _stacks[part_name]:
				read.append([entry, entry.instrument.get_playback_time() - base])
		if SfzInstrument.get_mix_epoch() != before:
			continue
		for pair in read:
			pair[0].offset = pair[1]
		return
	AudioServer.lock()
	var base_locked: float = _reference.get_playback_time()
	for part_name in _stacks:
		for entry in _stacks[part_name]:
			entry.offset = entry.instrument.get_playback_time() - base_locked
	AudioServer.unlock()


# Part defaults first, then each layer's own over the top. That order is what
# lets a stack be placed: the part says where it sits, and a layer that
# wants to sit a little to one side of it - a second kit a few degrees off the
# first, a section wider than the solo in front of it - says so once, here,
# instead of needing its own copy of the manifest.
func _apply_defaults() -> void:
	# Bus by bus: every part's controls, then every part's keyswitch. The
	# parts of one bus were one stack of layers before the registry, and that
	# stack set all its controls before it tapped a keyswitch; keeping the
	# order keeps a migrated score's load stream as it was.
	for bus in SfzEnsemble.BUSES:
		var names: Array = []
		for p: SfzEnsemble.Part in ensemble.parts_on(bus):
			if _stacks.has(p.name):
				names.append(p.name)
		for part_name in names:
			var part := ensemble.part(part_name)
			# Straight to every player rather than through cc(), which warns of a
			# control no layer hears; a default nobody hears is not news.
			for entry in _stacks[part_name]:
				var layer: SfzEnsemble.Layer = entry.layer
				for control in part.defaults:
					var number := layer.cc(control, part.cc(control))
					if number >= 0:
						_send_cc(entry, number,
							clampi(int(part.defaults[control]), 0, 127), -1.0)
				for control in layer.defaults:
					var number := layer.cc(control, part.cc(control))
					if number < 0:
						continue
					_send_cc(entry, number,
						clampi(int(layer.defaults[control]), 0, 127), -1.0)
		# Once per part: a part is every layer a voice used to split out, so
		# the one tap reaches them all.
		for part_name in names:
			var part := ensemble.part(part_name)
			if part.keyswitch_default != "":
				articulate(part_name, part.keyswitch_default)
