class_name SfzMusicDirector
extends Node

# Step 6: the part a game actually talks to.
#
# Everything below this line assumes one ensemble is loaded and one piece is
# playing. A game does not: the player walks through a door and the next area
# wants a different soundfont entirely, which takes seconds to parse off disk
# while the current music is still sounding.
#
# So there are two of everything. Two Conductors, each with its own five
# players, each on its own audio bus. One is the foreground; the other is
# idle. go_to() loads the next ensemble into the idle one - on worker threads,
# every layer at once, so neither the game nor the music playing now misses
# a frame - then hands over and unloads what is behind it.
#
# The handoff is in musical time. The game says where the music is going -
# go_to("battle") - and music/transitions.json says how: at the next bar, the
# next section, the end of the loop, or through the outgoing piece's ending;
# with a sting or without; with how long a fade. The outgoing piece is asked
# when that exit falls, and the incoming piece's first downbeat is put
# exactly there - on the other conductor's clock, which runs at the same rate
# and is measured against this one. Nothing about it is gameplay: the game
# decides what and when, the table decides how. A game that cannot wait says
# so, go_to(area, true), and the table's `max_wait` bounds the wait.
#
# An ensemble load before the handoff is seconds the exit cannot come before - up
# to sixteen for the largest ensemble. preload_area() is how a game avoids that
# for the areas it can see coming - the battle a random
# encounter may start, the room behind a door the player is walking towards:
# the idle slot loads it in the background, and go_to() for that area starts
# from the next bar. Loaded, the idle slot is held (SfzConductor.hold()): it
# renders nothing until the go_to() that plays it, which releases it before a
# note is placed on its clock.
#
# A held ensemble is all of its memory, for as long as it waits. So a preload
# has two depths. Hold.ENSEMBLE is the above. Hold.SCORES reads and compiles
# the score and stings and keeps them, and loads nothing: the go_to() that
# follows still loads the ensemble, and its exit waits for that, but it
# compiles nothing. A game holds SCORES for what might come and asks for
# ENSEMBLE when it is about to - preload_area() again, which reuses the
# compile - and release_preload() when it no longer is.
#
# The rest is what a game does to its music without changing it: a volume
# for its options menu (volume_db), ducking under dialogue (duck/unduck),
# stopping it dead for a pause menu or a cutscene (pause/resume), and saving
# where it had got to (state/restore). And one thing it does to the music
# without leaving it: `intensity`, which brings the lanes a score wrote as
# layers in and out on the bar - the drums arriving as a fight turns, the
# pad left alone when the room goes quiet. All of it is on the music bus - one
# bus every piece ends up on, "Music" by default - so none of it gets in the
# way of the fades between areas, which are on the two slots' own buses.
#
# The director runs whether or not the scene tree is paused: a pause menu
# usually wants its music. pause() is how to stop it; or set process_mode
# back to PROCESS_MODE_INHERIT to tie it to the tree's pause.

signal area_changed(area: String)
signal transition_finished(area: String)

# The director is free again: a transition, a preload or a silence has
# finished, or the queue has moved on. What a queued request waits on.
signal _turn

# How deep a preload goes: see the header.
enum Hold { SCORES, ENSEMBLE }

const BUSES: Array[StringName] = [&"MusicA", &"MusicB"]

# Quiet enough to be inaudible, loud enough that the fade back up is not a
# jump from digital silence.
const SILENT_DB := -60.0

# Past this much sample audio in memory - the heads both slots preload and the
# files sfizz streams for the notes playing - loading another ensemble
# alongside the current one is a decision rather than an accident. Two of the
# ensembles on the roster are large.
var memory_budget: int = 768 << 20

# What preload_area() does when it is not told.
var preload_hold: Hold = Hold.ENSEMBLE

# The crossfade for go_to_piece() without a rule, and for silence().
var fade_time: float = 2.5

# The music's level, for an options menu: linear_to_db(slider) for a slider
# from 0 to 1. Applies at once, on top of ducking and pausing.
var volume_db: float = 0.0:
	set(value):
		volume_db = value
		_apply_music_db()

# How much is going on, as a level from 0: lanes a score writes `layer:N`
# play from level N up. Set it and the change lands on the next bar of the
# piece playing; set_intensity() says when, or lands it elsewhere. It carries
# over to the next area - a fight is still a fight through a door - and
# state() saves it.
var intensity: int:
	get:
		return _intensity
	set(value):
		set_intensity(value)

# Where each area's music was left, in seconds into its piece: what a rule
# with `pick_up` comes back in at. state() and restore() carry it.
var positions: Dictionary = {}

# Empty reads the sfzplayer/paths/transitions project setting.
var table_path: String = ""
var table: SfzTransitions

var area: String = ""

var _conductors: Array[SfzConductor] = []
var _players: Array[SfzScorePlayer] = [null, null]
var _stings: Array[SfzScorePlayer] = [null, null]
var _front: int = 0
var _busy: bool = false
var _waiting := 0              # the one request queued behind _busy, by number
var _requests := 0             # numbers handed out so far
var _preloaded: String = ""    # the area whose ensemble the idle slot holds
var _last := {}                # the last handoff, for tests and meters
var _duck_db := 0.0
var _pause_db := 0.0
var _paused := false
var _mode := PROCESS_MODE_ALWAYS   # what pause() puts back
var _ramps := {}                   # "_duck_db"/"_pause_db" -> its Tween
var _intensity := 0
var _scores := {}                  # path -> SfzScore, parsed ahead by preload_area()
var _prepared := {}                # path -> SfzScorePlayer, compiled ahead by preload_area()
var _prepared_area := ""           # the area _prepared was compiled for
var _prepared_ensemble: SfzEnsemble    # and the manifest it was compiled against
var _last_read := {}
var _reading: Thread             # _read()'s thread while it runs, joined on free


# Freed while _read() waits - the game quitting mid-preload - the awaiting
# _read() is dropped with it, and its thread would run on into scripts already
# torn down.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _reading != null:
		_reading.wait_to_finish()


func _ready() -> void:
	if process_mode == PROCESS_MODE_INHERIT:
		process_mode = PROCESS_MODE_ALWAYS
	for i in 2:
		_ensure_bus(BUSES[i])
		var conductor := SfzConductor.new()
		conductor.name = "Conductor%s" % BUSES[i]
		conductor.bus = BUSES[i]
		add_child(conductor)
		_conductors.append(conductor)
		_set_db(i, SILENT_DB)
	if table_path == "":
		table_path = SfzSettings.transitions_path()
	if FileAccess.file_exists(table_path):
		table = SfzTransitions.load_from(table_path)
	_apply_music_db()


func is_busy() -> bool:
	return _busy


func is_playing() -> bool:
	var player := _players[_front]
	return player != null and player.is_playing()


# Seconds into the foreground piece; negative during its lead-in.
func position() -> float:
	var player := _players[_front]
	return player.position() if player != null else 0.0


func conductor() -> SfzConductor:
	return _conductors[_front]


# The foreground piece's player, for a meter or a test.
func foreground() -> SfzScorePlayer:
	return _players[_front]


# What the last go_to() did: {rule, how, exit, start, outro, outgoing_origin,
# incoming_origin, offset, drift} - the times in seconds, the origins on each
# conductor's own clock, `offset` the incoming clock minus the outgoing one
# and `drift` how far it had moved by the end of the fade.
func last_handoff() -> Dictionary:
	return _last


# Moves the music to intensity `level`, landing `at` "now", "beat", "bar" or
# "section" (see SfzScorePlayer.set_intensity()). Returns how many seconds
# from now it lands, or 0 with nothing playing - the next piece simply starts
# at it. Mid-transition both pieces take it, each on its own boundary. A
# landing the players do not know is an error: the level is not taken, here
# or by any player, and it returns -1.
func set_intensity(level: int, at: String = "bar") -> float:
	if not SfzScorePlayer.LANDINGS.has(at):
		push_error("MusicDirector: no landing called '%s' (%s)" % [at,
			", ".join(SfzScorePlayer.LANDINGS)])
		return -1.0
	level = maxi(level, 0)
	_intensity = level
	var soonest := 0.0
	for player: SfzScorePlayer in _players + _stings:
		if player == null:
			continue
		var when := player.set_intensity(level, at)
		if player == _players[_front] and player.is_playing():
			soonest = maxf(player.origin() + when - player.conductor.now(), 0.0)
	return soonest


# The area's music, made ready in the background: to `hold` (Hold; -1 for
# preload_hold). Returns whether it is ready to that depth or deeper.
func preload_area(new_area: String, hold: int = -1) -> bool:
	if not _has(new_area):
		return false
	if hold < 0:
		hold = preload_hold
	var back := 1 - _front
	if _preloaded == new_area and _conductors[back].is_loaded():
		return true
	if hold == Hold.SCORES and _prepared_area == new_area:
		return true
	if _busy:
		push_error("MusicDirector: cannot preload mid-transition")
		return false
	_busy = true
	var ok := true
	if _prepared_area != new_area:
		ok = await _prepare(new_area, back)
	if ok and hold == Hold.ENSEMBLE:
		var articulations := {}
		var played := {}
		for path: String in _prepared:
			_merge_articulations(articulations, _prepared[path].articulations())
			_merge_played(played, _prepared[path].played())
		ok = await _load(back, _prepared_ensemble, articulations, played)
		if ok:
			# Nothing plays it until go_to(): it waits without rendering.
			_conductors[back].hold()
			_meter("preloaded '%s'" % new_area, heads_memory())
		_preloaded = new_area if ok else ""
	elif ok:
		# An ensemble held for some other area is not what comes next.
		await _unload_back()
		_meter("prepared '%s' (scores only)" % new_area, heads_memory())
	_free()
	return ok


# Lets go of a preloaded ensemble, keeping the compiled scores: the area is
# still prepared, to the SCORES depth. False, and nothing done, mid-transition
# or with a request waiting.
func release_preload() -> bool:
	if _queued():
		return false
	if _preloaded == "":
		return true
	_busy = true
	var was := _preloaded
	await _unload_back()
	_meter("released '%s'" % was, heads_memory())
	_free()
	return true


# The area whose scores are compiled ahead, if any; preloaded() says whether
# its ensemble is held too.
func prepared_area() -> String:
	return _prepared_area


# Where the preloaded slot is, if anywhere.
func preloaded() -> String:
	return _preloaded


# Goes to `new_area`, as music/transitions.json says to from the area playing
# now. `urgent`: the game cannot wait for a phrase to end. Awaits until the
# transition is complete.
#
# Called mid-transition, it does not interrupt: the request waits for the
# transition under way to finish, then goes, by the rule from wherever that
# left the music. Only the latest waits - a request made while another is
# still waiting replaces it, and the one replaced returns false at once. The
# game asked for the battle, then the field again before the battle could
# start: the field is what it wants now. If the area waited for is the one
# playing by the time its turn comes, it returns true without moving.
#
# `from` starts the new piece that many seconds in (at the bar); by default it
# starts from the top, or where it was left if the rule says `pick_up`.
func go_to(new_area: String, urgent: bool = false, from: float = -1.0) -> bool:
	if not _has(new_area):
		return false
	# Mid-transition, `area` is where the music was, not where it is going:
	# the question waits too.
	if _queued() and not await _wait_turn():
		return false
	if new_area == area and is_playing():
		return true
	var rule := table.rule(area if is_playing() else "", new_area, urgent)
	if from < 0.0:
		from = float(positions.get(new_area, 0.0)) if rule["pick_up"] else 0.0
	return await go_to_piece(new_area, table.ensemble_path(new_area),
		table.score_path(new_area), rule, from)


# The same without the table: this ensemble, this score, this rule (the fields of
# a Transitions rule; missing ones default). With no rule at all, a plain
# crossfade of fade_time, starting now.
func go_to_piece(new_area: String, ensemble_path: String, score_path: String,
		rule: Dictionary = {}, from: float = 0.0) -> bool:
	# A `from` play_at() would refuse is refused here: below, the piece
	# playing is given its way out before play_at() runs, and that cannot be
	# taken back. Refused, the piece playing plays on as it was, no ensemble is
	# read and no request waiting is replaced.
	if is_nan(from) or is_inf(from) or from < 0.0:
		push_error("MusicDirector: from %s is not a time in the piece" % from)
		return false
	if _queued():
		if not await _wait_turn():
			return false
		if new_area == area and is_playing():
			return true

	var full := SfzTransitions.DEFAULTS.duplicate()
	if rule.is_empty():
		full.merge({"exit": "now", "fade": fade_time, "fade_in": fade_time}, true)
	full.merge(rule, true)
	rule = full

	_busy = true
	var back := 1 - _front
	var front := _front

	# The score, the sting and the ensemble's manifest are files to read and parse,
	# so a worker thread does it - but not the scores preload_area() already
	# has, which are what a transition to a preloaded area plays.
	var sting_path: String = SfzTransitions.sting_path(rule["sting"]) \
		if rule["sting"] != "" else ""
	var wanted := [score_path] if sting_path == "" else [score_path, sting_path]
	var read := await _read(_uncached(wanted), ensemble_path)
	var scores: Dictionary = read["scores"]
	for path: String in wanted:
		if not scores.has(path):
			scores[path] = _scores[path]
	# Kept no longer than the transition they were read for: a score edited
	# on disk is read again next time.
	_scores.clear()
	var prepared := _prepared
	_prepared = {}
	_prepared_area = ""
	_prepared_ensemble = null
	_last_read = {"parsed": read["parsed"], "cached": wanted.size() - read["parsed"],
		"on_main_thread": read["on_main_thread"]}
	var score: SfzScore = scores[score_path]
	var sting: SfzScore = scores[sting_path] if sting_path != "" else null
	if score == null:
		_free()
		return false
	var ensemble: SfzEnsemble = read["ensemble"]
	if ensemble == null:
		_free()
		return false
	# Compiled on a thread, before anything is loaded: what the piece and its
	# sting switch to is all of the ensemble that is loaded, and the exit is
	# chosen against what has already been sent.
	var incoming: SfzScorePlayer = prepared.get(score_path)
	if incoming == null:
		incoming = _player(back)
		await incoming.prepare(score, ensemble)
	var sting_player: SfzScorePlayer = null
	var articulations := incoming.articulations()
	var played := incoming.played()
	if sting != null:
		sting_player = prepared.get(sting_path)
		if sting_player == null:
			sting_player = _player(back)
			await sting_player.prepare(sting, ensemble)
		_merge_articulations(articulations, sting_player.articulations())
		_merge_played(played, sting_player.played())
	for path: String in prepared:
		if prepared[path] != incoming and prepared[path] != sting_player:
			prepared[path].queue_free()
	var warm := _preloaded == new_area and _conductors[back].is_loaded() \
		and _conductors[back].ensemble.id == ensemble.id \
		and _conductors[back].covers(articulations, played)
	_preloaded = ""
	if not warm and not await _load(back, ensemble, articulations, played):
		for player: SfzScorePlayer in [incoming, sting_player]:
			if player != null:
				player.queue_free()
		_free()
		return false
	# A preloaded slot's clocks stood still while it was held. Started again
	# here, before the offset is read and before anything is placed on its
	# clock, the exit and the downbeat are on the grid exactly as they are for
	# a slot that never stopped: both clocks count frames mixed in the same
	# step from here on, and the offset is measured after.
	_conductors[back].release()
	var loaded_heads := heads_memory()
	incoming.set_intensity(_intensity)   # moved while it compiled?

	# Everything below is in musical time, and quick: the exit is chosen
	# against what has been sent, and the next frame sends more.
	var leaving: SfzScorePlayer = _players[front]
	if leaving != null and not leaving.is_playing():
		leaving = null
	var offset := 0.0
	if leaving != null:
		offset = _clock_offset(_conductors[front], _conductors[back])

	var plan := SfzTransitions.leave(leaving, rule,
		leaving.position() if leaving != null else 0.0)
	if leaving != null:
		var left_at := float(plan["exit"])
		positions[area] = left_at if is_finite(left_at) else leaving.position()
	var origin := -INF
	if leaving != null and plan["how"] != "now":
		origin = leaving.origin() + float(plan["start"]) + offset

	if sting_player != null:
		sting_player.play_at(sting, origin)
		origin = sting_player.origin() + sting.duration()
	# play_at()'s other refusals cannot happen here: the ensemble is loaded, the
	# score read, the intensity never below 0, and the origin is the leaving
	# piece's own times. Were one to, the piece playing has its way out already.
	if not incoming.play_at(score, origin, from):
		for player: SfzScorePlayer in [incoming, sting_player]:
			if player != null:
				player.stop()
				player.queue_free()
		_free()
		return false
	var handoff := sting_player.origin() if sting_player != null else incoming.downbeat()

	_last = {"read": _last_read, "rule": rule, "how": plan["how"], "exit": plan["exit"],
		"start": plan["start"], "outro": plan["outro"], "offset": offset, "drift": 0.0,
		"outgoing_origin": leaving.origin() if leaving != null else 0.0,
		"incoming_origin": handoff}

	_players[back] = incoming
	_stings[back] = sting_player
	area = new_area
	_front = back
	area_changed.emit(new_area)

	var fade_in: float = rule["fade_in"]
	_set_db(back, SILENT_DB if fade_in > 0.0 else 0.0)

	# The fades are on the game's clock and the handoff is on the audio's, so
	# they are started from the audio's: the first frame past the downbeat.
	await _until(_conductors[back], handoff)
	var fade: float = rule["fade"]
	var falling := _fade(front, SILENT_DB, maxf(fade, 0.01))
	var rising: Tween = _fade(back, 0.0, fade_in) if fade_in > 0.0 else null
	await falling.finished

	# The offset again, both clocks having run through the handoff: if it has
	# moved, the downbeat was not where it was put.
	if leaving != null:
		_last["drift"] = _clock_offset(_conductors[front], _conductors[back]) - offset

	# Only now is the old ensemble unreachable, and only now is its memory worth
	# giving back - at once, not when a longer fade in has finished: silent, it
	# still renders, and sfizz lets go of the files it streamed only as it does.
	_drop(front)
	_conductors[front].unload()
	await _conductors[front].freed()
	if rising != null and rising.is_running():
		await rising.finished
	_meter("landed '%s'" % new_area, loaded_heads)

	_busy = false
	transition_finished.emit(new_area)
	_turn.emit()
	return true


# Fades the foreground out over `seconds` (fade_time when negative) and unloads
# it. The director is left with nothing playing and both ensembles gone.
# Mid-transition it waits for the transition to land, as go_to() would, and
# replaces any request waiting behind it.
func silence(seconds: float = -1.0) -> void:
	var fade := fade_time if seconds < 0.0 else seconds
	if _queued() and not await _wait_turn():
		return
	_busy = true
	var player: SfzScorePlayer = _players[_front]
	if player != null:
		player.window = fade + SfzScorePlayer.WINDOW
	await _fade(_front, SILENT_DB, fade).finished
	_drop(_front)
	_conductors[_front].unload()
	if _conductors[1 - _front].is_loaded():
		_conductors[1 - _front].unload()
	for c in _conductors:
		await c.freed()
	_preloaded = ""
	_free_prepared()
	area = ""
	_free()


# Brings the music down under something that has to be heard over it -
# dialogue, a cutscene's voice - by `db`, over `seconds`. unduck() puts it
# back. Calling again moves it to the new depth.
func duck(db: float = -10.0, seconds: float = 0.25) -> void:
	_ramp("_duck_db", db, seconds)


func unduck(seconds: float = 0.8) -> void:
	_ramp("_duck_db", 0.0, seconds)


# Stops the music where it is, after a fade of `seconds` short enough not to
# be heard as one: every clock stops with it, so resume() carries on from
# the same sample, mid-note, mid-transition, and nothing scheduled moves.
func pause(seconds: float = 0.12) -> void:
	if _paused:
		return
	_paused = true
	_mode = process_mode
	var tween := _ramp("_pause_db", SILENT_DB, seconds)
	await tween.finished
	# Disabled, every player under the director stops mixing, and the tweens
	# and score players stop with them.
	if _paused:
		process_mode = PROCESS_MODE_DISABLED


func resume(seconds: float = 0.12) -> void:
	if not _paused:
		return
	_paused = false
	process_mode = _mode
	_ramp("_pause_db", 0.0, seconds)


func is_paused() -> bool:
	return _paused


# Where the music is, for a save file: plain data, JSON-safe. restore() with
# it, after loading, brings the same area back in at the bar it was at.
func state() -> Dictionary:
	var here := positions.duplicate()
	if area != "" and is_playing():
		here[area] = position()
	return {"area": area, "positions": here, "intensity": _intensity}


func restore(saved: Dictionary) -> bool:
	positions = (saved.get("positions", {}) as Dictionary).duplicate()
	set_intensity(int(saved.get("intensity", _intensity)))
	var saved_area: String = saved.get("area", "")
	if saved_area == "":
		return true
	return await go_to(saved_area, false, float(positions.get(saved_area, 0.0)))


# Bytes of preloaded sample heads the two slots are holding between them
# (SfzConductor.memory_estimate()): not the files streamed for the notes
# playing, and not sfizz's own bookkeeping. _meter() logs those beside it.
func heads_memory() -> int:
	var total := 0
	for c in _conductors:
		if c.is_loaded():
			total += c.memory_estimate()
	return total


# Both slots, foreground first. Meters want the outgoing one too: the whole
# question during a transition is whether it kept its footing.
func conductors() -> Array[SfzConductor]:
	return [_conductors[_front], _conductors[1 - _front]]


func stats() -> Dictionary:
	return _conductors[_front].stats()


# --- Internals -----------------------------------------------------------

func _has(new_area: String) -> bool:
	if table == null:
		push_error("MusicDirector: no transitions table at %s" % table_path)
		return false
	if not table.has_area(new_area):
		push_error("MusicDirector: no area called '%s'" % new_area)
		return false
	return true


# Queues the caller behind the transition under way, replacing whatever was
# queued there: that one wakes and is told false. True when it is the
# caller's turn - the director free, and nothing asked for since.
func _wait_turn() -> bool:
	_requests += 1
	var mine := _requests
	_waiting = mine
	_turn.emit()
	while _busy and _waiting == mine:
		await _turn
	if _waiting != mine:
		return false
	_waiting = 0
	return true


# Busy, or a request is still waiting for its turn. The second is true for a
# moment with _busy false: from the end of a transition until _turn wakes the
# waiter, which is when transition_finished listeners run. A go_to() from one
# of them must queue behind the waiter (and so replace it), not jump it.
func _queued() -> bool:
	return _busy or _waiting != 0


func _free_prepared() -> void:
	for path: String in _prepared:
		_prepared[path].queue_free()
	_prepared = {}
	_prepared_area = ""
	_prepared_ensemble = null


# Reads and compiles `new_area`'s score and the stings the table would play
# on the way in, keeping them: what they switch to is all of the ensemble
# that is loaded (SfzConductor.load_ensemble), and the go_to() that follows
# plays them as they are. Compiling is most of a transition that has nothing
# to load.
func _prepare(new_area: String, back: int) -> bool:
	_free_prepared()
	var from := area if is_playing() else ""
	var paths := [table.score_path(new_area)]
	for urgent in [false, true]:
		var sting: String = table.rule(from, new_area, urgent)["sting"]
		if sting != "":
			paths.append(SfzTransitions.sting_path(sting))
	var read := await _read(_uncached(paths), table.ensemble_path(new_area))
	for path: String in read["scores"]:
		if read["scores"][path] != null:
			_scores[path] = read["scores"][path]
	var ensemble: SfzEnsemble = read["ensemble"]
	if ensemble == null:
		return false
	for path: String in paths:
		if _scores.has(path):
			var player := _player(back)
			await player.prepare(_scores[path], ensemble)
			_prepared[path] = player
	_prepared_area = new_area
	_prepared_ensemble = ensemble
	return true


# Empties the idle slot, if it holds anything.
func _unload_back() -> void:
	var back := 1 - _front
	if _conductors[back].is_loaded():
		_conductors[back].unload()
		await _conductors[back].freed()
	_preloaded = ""


func _free() -> void:
	_busy = false
	_turn.emit()


# Loads an ensemble into `slot`, replacing whatever is there, with only the
# `articulations` and `played` keys (see SfzConductor.load_ensemble) the
# pieces it is for play.
# load_ensemble() unloads what was there first and waits for it to be freed,
# so a stale preload is gone before the new ensemble is read.
func _load(slot: int, ensemble: SfzEnsemble, articulations: Dictionary,
		played: Dictionary) -> bool:
	return await _conductors[slot].load_ensemble(ensemble, articulations, played)


# Adds `more`'s articulations (part -> names) to `into`'s.
static func _merge_articulations(into: Dictionary, more: Dictionary) -> void:
	for part_name: String in more:
		var arts: Array = into.get_or_add(part_name, [])
		for articulation: String in more[part_name]:
			if not arts.has(articulation):
				arts.append(articulation)


# Adds `more`'s played keys and drums (part -> {"keys", "drums"}) to `into`'s.
static func _merge_played(into: Dictionary, more: Dictionary) -> void:
	for part_name: String in more:
		var plays: Dictionary = into.get_or_add(part_name, {"keys": [], "drums": []})
		for list: String in ["keys", "drums"]:
			for what: Variant in more[part_name][list]:
				if not (plays[list] as Array).has(what):
					(plays[list] as Array).append(what)


func _uncached(paths: Array) -> Array:
	return paths.filter(func(path: String) -> bool: return not _scores.has(path))


# Parses each score in `score_paths`, and the ensemble manifest at `ensemble_path`
# unless it is empty, on a worker thread. Hands back {scores: {path: SfzScore
# or null}, ensemble, parsed, on_main_thread}. The thread touches nothing shared:
# what it builds is its own, and is read only once the thread is joined.
func _read(score_paths: Array, ensemble_path: String) -> Dictionary:
	if score_paths.is_empty() and ensemble_path == "":
		return {"scores": {}, "ensemble": null, "parsed": 0, "on_main_thread": 0}
	_reading = Thread.new()
	_reading.start(_read_files.bind(score_paths, ensemble_path))
	while _reading.is_alive():
		await get_tree().process_frame
	var read: Dictionary = _reading.wait_to_finish()
	_reading = null
	return read


# `on_main_thread` counts the scores parsed where the game would wait for
# them: none, while this runs on the thread _read() starts.
static func _read_files(score_paths: Array, ensemble_path: String) -> Dictionary:
	var scores := {}
	for path: String in score_paths:
		scores[path] = SfzScoreParser.parse_file(path)
	var on_main := OS.get_thread_caller_id() == OS.get_main_thread_id()
	return {"scores": scores,
		"ensemble": SfzEnsemble.load_from(ensemble_path) if ensemble_path != "" else null,
		"parsed": score_paths.size(),
		"on_main_thread": score_paths.size() if on_main else 0}


func _player(slot: int) -> SfzScorePlayer:
	var player := SfzScorePlayer.new(_conductors[slot])
	player.compiler = SfzPerformanceCompiler.new()
	player.intensity = _intensity
	add_child(player)
	return player


func _drop(slot: int) -> void:
	for player: SfzScorePlayer in [_players[slot], _stings[slot]]:
		if player != null:
			player.stop()
			player.queue_free()
	_players[slot] = null
	_stings[slot] = null


# The incoming clock minus the outgoing one. Both count frames mixed, in the
# same mix step, so the difference is constant - but the step mixes one
# playback after another, and a read that lands between the two is a block
# out. With a heavy ensemble that is most reads, not a few. So the read is taken
# between steps rather than inside one, proved by the mix epoch either side
# of it, and only falls back to locking the audio server if it cannot get a
# clean pair.
#
# How many times to try for that gap before giving up and taking the lock. A
# step is microseconds of work; a miss means the reader landed inside one,
# and the next attempt lands after it.
const CLOCK_READ_TRIES := 64


func _clock_offset(from: SfzConductor, to: SfzConductor) -> float:
	# Read both clocks between two mix steps rather than holding the step off.
	# Locking gave the same guarantee, but it made the game thread wait out
	# however long the mix thread took - and under load the mix thread can be
	# descheduled while holding that lock, which cost 14-64 ms a call and no
	# priority we can set fixes. The epoch is bumped on the way into and out
	# of every _mix(), so unchanged and even across the read means the same
	# step produced both numbers. Falls back to the lock if the mixer is busy
	# enough that no window opens, which keeps the guarantee unconditional.
	for _attempt in CLOCK_READ_TRIES:
		var before: int = SfzInstrument.get_mix_epoch()
		if before % 2 == 1:
			continue
		var offset := to.now() - from.now()
		if SfzInstrument.get_mix_epoch() == before:
			return offset
	AudioServer.lock()
	var locked := to.now() - from.now()
	AudioServer.unlock()
	return locked


func _until(clock: SfzConductor, t: float) -> void:
	while clock.is_loaded() and clock.now() < t:
		await get_tree().process_frame


# Straight in amplitude, not in decibels. A dB ramp to SILENT_DB is -30 dB
# halfway, so a six second fade is gone to the ear in two; this one is -6 dB
# halfway and lasts as long as it says. tools/splice_sequence.py draws the
# same curve.
func _fade(slot: int, to_db: float, seconds: float) -> Tween:
	var from := db_to_linear(_db(slot))
	var to := db_to_linear(to_db)
	var tween := create_tween()
	tween.tween_method(func(x: float) -> void:
			_set_db(slot, maxf(linear_to_db(lerpf(from, to, x)), SILENT_DB)),
			0.0, 1.0, seconds)
	return tween


# volume_db, the duck and the pause, on the one bus the music ends up on.
func _apply_music_db() -> void:
	var index := AudioServer.get_bus_index(SfzMixer.music_bus())
	if index >= 0:
		AudioServer.set_bus_volume_db(index, volume_db + _duck_db + _pause_db)


# The duck or the pause moving to `to_db`, straight in amplitude as _fade().
func _ramp(property: String, to_db: float, seconds: float) -> Tween:
	var old: Tween = _ramps.get(property)
	if old != null and old.is_valid():
		old.kill()
	var from := db_to_linear(float(get(property)))
	var to := db_to_linear(to_db)
	var tween := create_tween()
	tween.tween_method(func(x: float) -> void:
			set(property, maxf(linear_to_db(lerpf(from, to, x)), SILENT_DB))
			_apply_music_db(),
			0.0, 1.0, maxf(seconds, 0.001))
	_ramps[property] = tween
	return tween



func _set_db(slot: int, db: float) -> void:
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index(BUSES[slot]), db)


func _db(slot: int) -> float:
	return AudioServer.get_bus_volume_db(AudioServer.get_bus_index(BUSES[slot]))


# The fader this slot crossfades. Mixer builds it and the six family buses
# that feed it; doing it here rather than at load time means _set_db() below
# has something to set before the first ensemble is anywhere near loaded.
func _ensure_bus(name: StringName) -> void:
	SfzMixer.ensure(name)


# One line per preload and per transition landed: the sample audio in memory
# - heads and streamed files, while the extension can count the second - and
# the process's private bytes, which is what the machine actually gives up.
# `peak_heads` is the heads while both slots were loaded. A budget is not a
# limit - refusing to load the area the player just walked into would be worse
# than the memory. It is a place for the number to be noticed, with the
# per-part preload sizes that would bring it down.
func _meter(what: String, peak_heads: int) -> void:
	var heads := heads_memory()
	var streamed: int = SfzInstrument.get_streamed_bytes()
	var samples := heads + maxi(streamed, 0)
	var line := "MusicDirector: %s - heads %.0f MB (%.0f MB with both slots)" % [
		what, heads / 1048576.0, peak_heads / 1048576.0]
	if streamed >= 0:
		line += ", streamed %.0f MB" % (streamed / 1048576.0)
	line += ", process private %.0f MB" % (SfzInstrument.get_process_private_bytes() / 1048576.0)
	print(line)
	if maxi(samples, peak_heads) > memory_budget:
		push_warning("MusicDirector: %.0f MB of samples resident at %s, over the %.0f MB budget" % [
			maxi(samples, peak_heads) / 1048576.0, what, memory_budget / 1048576.0])
