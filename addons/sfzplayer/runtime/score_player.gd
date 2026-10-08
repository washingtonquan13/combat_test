class_name SfzScorePlayer
extends Node

# Plays a Score through a SfzConductor.
#
# The musical decisions are not made here. A ScoreCompiler turns the score
# into a flat, time-sorted list of notes, hits, keyswitches and CC points,
# and this class does nothing but hand them to the Conductor at the right
# moment. Swapping ScoreCompiler (literal) for PerformanceCompiler (step 5) changes
# everything about how the piece sounds and nothing about this file, which
# is what makes the two comparable.
#
# A score with a loop (`order: intro [a b] outro`) plays the intro, then the
# loop until leave_loop() is called, then the outro. Nothing is crossfaded:
# the next pass is scheduled like any other music, so the last pass's
# releases and reverb ring on into the next one, exactly as they would
# between two sections, and the join is sample-accurate. The way out can be
# the end of the pass, or the next section or bar - see leave_loop().
#
# Every pass must sound like the one before it, and a compiler reading the
# piece once would not give that: whatever runs across sections - a rotary
# cabinet spinning, a slur left open - arrives at the loop from the intro the
# first time and from the loop's own end every time after. So the piece is
# compiled with the loop written twice. The intro and the first copy play once;
# the second copy, which was performed coming out of the first, is what
# repeats; the outro was performed coming out of that. Seeds come from the
# lanes rather than from the clock, so the copies are otherwise identical.
#
# Events are streamed rather than dumped: the C++ side takes 2048 queued
# events and 4096 pending ones, and a five minute piece is bigger than that.
# Everything inside WINDOW seconds of now goes out each frame, which keeps
# the queue shallow and lets stop() actually stop.
#
# Lanes written `layer:N` are intensity layers: the game raises and lowers
# the intensity and they come in and drop out, on a bar, without the piece
# changing under them - see set_intensity(). Nothing is recompiled for it.
# Every lane is compiled and streamed as always, and the ones outside the
# level are held back at the moment they would have been sent, so a layer
# that comes in is exactly where it would have been had it played all along.

signal finished


# Events are handed to the scheduler this far in advance. Comfortably more
# than a frame, comfortably less than the queue depth.
const WINDOW := 0.75

# The live value. Widened while something expensive is about to happen on
# the game thread - loading the next area's ensemble, most of all - so the music
# is already in the audio thread's hands before the frames stop arriving.
var window: float = WINDOW

var conductor: SfzConductor
var score: SfzScore

# Added to the Conductor's measured lead. A crossfade wants the incoming
# piece to start after the fade has begun, not underneath the outgoing one.
var extra_lead: float = 0.0

# What turns beats and intent into events. Defaults to the literal compiler;
# set it to a PerformanceCompiler before play() for the shaped reading.
var compiler: SfzScoreCompiler = SfzScoreCompiler.new()

# How many times the loop plays before the outro: 0 until leave_loop(), or a
# number for a render or a test that has to end by itself. The first pass
# counts. Ignored for a score without a loop.
var loop_passes: int = 0

# How many separately performed passes of the loop to compile before they
# start repeating. 1 is what this player did for its whole life: one pass,
# played over and over, bit-identical every time round, which is a tape loop
# rather than a band. 2 or 3 is a band playing the figure again - the notes
# are the same and the jitter, the drift and the velocities are not.
#
# It costs a compile of the loop per variation and that much memory, so it is
# a number rather than a switch: a long piece looping twice before a cue
# wants 2, a battle theme that will play for ten minutes wants 3 or 4.
# Ignored for a score without a loop.
var loop_variations: int = 2:
	set(value):
		loop_variations = maxi(1, value)

# The ways out of a loop, latest first: see leave_loop(). "section:NAME",
# the next time a named section comes round, is a way out too.
const EXITS: Array[String] = ["pass", "section", "bar", "beat"]

# A cut leaves the loop this long before the boundary it lands on. Notes still
# sounding are let go there and whatever the loop had not reached is dropped:
# the breath a band takes before the hit, and room for a release to land
# before the outro presses the same key again rather than on top of it.
const CUT_LIFT := 0.045

# Starting partway in, a note already held at the start point is played from
# there for what is left of it - the pad chord under the bar, the bass note
# tied across it - unless that is less than this.
const CATCH := 0.25

# An event written on the very first beat is not compiled at the very first
# beat. Every part sits somewhere against the grid and drums sit ahead of it
# (SfzPerformanceCompiler.POCKET is -4ms for perc and -30ms for pads), the
# feel adds jitter and drift, an accent rushes, and a lane's own pocket moves
# it again - all of which can put the downbeat a few milliseconds before the
# start of the piece. Worst case across the named vocabulary is 77ms: a pad
# lane, loose, pushed, with an accent.
#
# That is a placement inside the music, not a moment that has already passed,
# so an event this far before the start point is played at it rather than
# dropped. Further back than this and it really is in the past - a seek landed
# after it - where a hit piling onto the seek point is the wrong answer.
#
# This is why the piece used to open with no drums on beat one: perc leads by
# 4ms, a hit carries no duration for CATCH to measure, and it fell off the
# front of the render.
const PLACED_EARLY := 0.08

# Where a cut returns a control the ensemble gives no resting value: pedal up, no
# legato, no vibrato, no bend. Dynamics and brightness are left alone - every
# lane of the outro sets its own.
const RESTING := {"sustain": 0, "legato_attack": 0, "vibrato_depth": 0, "bend": 64}

# The ways a change of intensity lands, soonest first: see set_intensity().
const LANDINGS: Array[String] = ["now", "beat", "bar", "section"]

# The boundaries next_boundary() can find, and "section:NAME".
const BOUNDARIES: Array[String] = ["beat", "bar", "section", "end"]

# A layer's notes belong to the level at the beat they were written on, and a
# performed note can sit a little ahead of it - a pushed pocket, the drummer
# on top of the beat, a lane's setup. So a change counts from this much before
# its boundary.
const LAYER_EARLY := 0.05

# The intensity the piece starts at. Set it before play(); afterwards, use
# set_intensity(), which lands the change on the music's own boundaries.
var intensity: int = 0

# The three parts of a compiled piece, each sorted by "t", seconds from the top
# of the piece. Without a loop, everything is in _head.
var _head: Array = []       # the intro and the loop's first pass
# Later passes of the loop, each performed coming out of the one before,
# each timed as the pass it was compiled as: _bodies[k] sits a further loop
# length on. They are played in order and then from the start again.
var _bodies: Array[Array] = []
var _tail: Array = []       # the outro, timed as if it followed the last body
var _loop_length := 0.0
var _loop_end := 0.0        # where the first pass ends
var _lead_in := 0.0         # how far before a pass its earliest event falls
var _loop_start := 0.0      # where the first pass starts
var _marks := {}            # exit -> its boundaries in the first pass, in seconds
var _intro_marks := {}      # "section", "bar", "beat" -> the intro's own, before the loop

# What is scheduled so far: {events, next, offset[, stop]} per part, in the
# order they were committed. Several run at once near a join. `stop` is where
# a cut ends a part; nothing in it at or after that time is sent.
var _parts: Array = []
var _passes := 0            # passes of the loop committed, the first included
var _leaving := false
var _bare := false          # leaving without the outro: the piece just stops
var _closed := false        # the outro, or the whole piece, is committed
var _decided := false       # the way out is settled; nothing can be cut now
var _exit := INF            # where the loop is left, once it is decided
var _horizon := -INF        # everything up to here has been sent

# Releases not sent yet, earliest first: {end, seq, start, note_end, event,
# part}. While a loop can still be cut, a note that could be ringing at the cut
# has its release held back until its own time, which is what lets a cut move
# it earlier; every other release goes out with its press.
var _offs: Array = []
var _seq := 0

# A piece without a loop sends every release with its press, as it always
# has - holding them back reorders ties the renderer resolves by arrival. So a
# cut there cannot move a release; instead it remembers what is sounding and
# lets it go with a second, earlier release. The written one then finds
# nothing to stop.
var _sounding: Array = []

# The last value sent for each control, "part|control" -> the event, so
# a cut knows what it is leaving away from rest.
var _cc_last: Dictionary = {}

# The intensity over time: [seconds from the top, level] pairs, in order,
# the first at -INF. A change is a pair at its boundary.
var _levels: Array = []

# What a layer held back, for when it comes in: its notes, while they could
# still be sounding at a later boundary ({event, start, end}), and the last
# control and articulation each silent lane sent ("part|control" ->
# event), so it comes in with the dynamics and the keyswitch it would have had.
var _held_notes: Array = []
var _held_state: Dictionary = {}

var _origin: float = 0.0    # conductor time the piece starts at
# Seconds from the top of the event _dispatch() is sending - of its press, for
# a release - which is what a layer's take is read at (SfzConductor.note).
# Read off the piece rather than the conductor's clock, so the same note takes
# the same way wherever the piece is placed, live or offline.
var _take_at: float = 0.0
var _from: float = 0.0      # seconds in the piece began from; nothing before sounds
# What prepare() built, for play_at() with the same score to install: see
# _build(). Empty when there is none.
var _plan: Dictionary = {}
# The thread prepare() compiles on, while it runs: joined on free, since it
# runs this script's code and must not outlive it.
var _compiling: Thread
# The thread prepare() says the plan's findings on, joined as _compiling is.
# Saying a line is a console or editor write, 4 to 30 ms each on Windows, and
# the title piece has four to say: a tenth of a second the music would wait
# for, after the compile it needs, for words it does not.
var _saying: Thread
# "part|drum" for every drum this score hits that the ensemble's kit does not map.
# Those hits are skipped, as the conductor would skip them, so the conductor's
# own once-per-call warning is kept for a game's direct hit() - this piece
# has already said it, at prepare, once. See _report().
var _unmapped: Dictionary = {}

# The installed score's cast on this ensemble: score part -> {part, step}, the
# ensemble part that plays it and the step of SfzEnsemble.resolve that found it.
# Every event is sent to its score part's cast.
var _cast: Dictionary = {}

# What the installed plan found this ensemble cannot do with this score, keyed
# "part|item" (item "cast", "drum", "art:NAME", "control:NAME", "fit" or
# "velocity"), each {part, item, text, dropped}, by score part:
# the warning's words, and how many of the plan's events the finding sends
# nowhere (0 for a fallback, which leaves nothing in the plan). Every one is
# kept, said or not, so tools/check.gd can print a score's findings each
# time it is asked. See _report().
var _findings: Dictionary = {}

# "ensemble|score|part|item" already reported, by any player in this run: a piece
# prepared again, or by the next area's player, has nothing new to say.
static var _reported: Dictionary = {}
static var _reported_mutex := Mutex.new()
var _end: float = 0.0
var _count := 0
var _playing := false


func _init(new_conductor: SfzConductor = null) -> void:
	conductor = new_conductor


func is_playing() -> bool:
	return _playing


# Piece time on the dispatch clock: conductor.now() - origin(), seconds from
# the top as the conductor's mix has reached it; negative during the lead-in.
# It runs about one output latency ahead of what is heard - the samples at
# position() are still in the driver's buffer - so it is not the moment a
# listener hears that point of the piece.
func position() -> float:
	if not _playing:
		return 0.0
	return conductor.now() - _origin


func play(new_score: SfzScore) -> bool:
	return play_at(new_score, -INF)


# Starts the piece with its first downbeat at `origin` on the conductor's
# clock - the moment another piece is leaving, when this one is taking over
# from it. A moment too close to be kept is moved to the first one that can
# be: a downbeat late is a stumble, a downbeat half sent is a crash.
#
# `from` starts it that many seconds in rather than at the top - where a saved
# game or an area the player left had got to - moved back to the barline at
# or before it, a pass of a loop folded onto the first. The bar is put at
# `origin`. Nothing written before it sounds, bar the notes still held across
# it (CATCH); the controls it set are set, at the bar, so the part picks up
# with the pedal, the articulation and the dynamics it had there.
#
# `trim` false leaves the bus's loudness trim as it is (see below): for a
# sting over a piece already playing, a chained ending, or a second player on
# a bus that is already playing something at its own level.
#
# Returns true once the piece is started. A call it cannot keep is refused:
# push_error, false, and nothing changes - whatever was playing plays on as it
# was. Refused: no ensemble loaded; a null score; an origin that is NAN or +INF
# (-INF is "as soon as can be", which is what play() asks); a `from` that is
# NAN, INF or negative; and a starting `intensity` below 0. A `from` past the
# end of a piece that does not loop is not refused: it is the top again (see
# _seek_point()), which is what the director's pick-up relies on.
func play_at(new_score: SfzScore, origin: float, from: float = 0.0,
		trim: bool = true) -> bool:
	if not SfzConductor._on_main("SfzScorePlayer.play_at"):
		return false
	var refused := _play_error(new_score, origin, from)
	if refused != "":
		push_error("ScorePlayer: play_at refused: " + refused)
		return false
	if not _plan.is_empty() and _plan["score"] == new_score 			and _plan["ensemble"] == conductor.ensemble.id:
		_install(_plan)
	else:
		_prepare(new_score)
	_plan = {}
	_from = _seek_point(from)
	# Each score's own level, so every piece plays at the same loudness and
	# a handoff between two of them does not jump. It is a trim at the head
	# of the conductor's bus, ahead of the master chain, which is where the
	# offline renderer applies the same number. Offline there is no bus: the
	# render reads the table itself (tools/render.gd).
	#
	# A sting played just before the score on the same conductor goes out
	# at the score's trim, because it is the same bus and the score's
	# play_at() follows the sting's in the same frame. Stings are written
	# against the ensemble of the piece they introduce, so that is the level
	# they were meant to have.
	if trim and not conductor.is_offline() and conductor.bus != &"":
		SfzMixer.set_trim(conductor.bus, SfzLoudness.gain_db(new_score, conductor.ensemble.id))
	# The first note sits one measured lead ahead of the clock; everything
	# after it is relative to that, so this is the only place latency enters.
	_origin = maxf(origin, conductor.now() + conductor.lead() + extra_lead) - _from
	_playing = true
	set_process(true)
	return true


# Why play_at() cannot keep a call, or "" when it can. Reads nothing it would
# change.
func _play_error(new_score: SfzScore, origin: float, from: float) -> String:
	if conductor == null or not conductor.is_loaded():
		return "no ensemble loaded"
	if new_score == null:
		return "no score"
	if is_nan(origin) or origin == INF:
		return "origin %s is not a time" % origin
	if is_nan(from) or is_inf(from) or from < 0.0:
		return "from %s is not a time in the piece" % from
	if intensity < 0:
		return "intensity %d is below 0" % intensity
	return ""


# Compiles `new_score` on a worker thread, ahead of play()/play_at() with the
# same score. A long piece is a couple of hundred milliseconds of compiling -
# a hitch the player sees, on the frame the music changes. Await it; the
# player has to be in the tree. Whatever this player is playing meanwhile
# plays on untouched; the compiled piece is kept aside until play_at().
#
# `against` compiles for that ensemble instead of the one loaded, which need
# not be loaded at all: how the director learns what a piece will ask of an
# ensemble (articulations()) before loading it. play_at() takes the piece
# only once an ensemble of the same id is loaded; otherwise it compiles again.
func prepare(new_score: SfzScore, against: SfzEnsemble = null) -> void:
	if against == null and (conductor == null or not conductor.is_loaded()):
		push_error("ScorePlayer: no ensemble loaded")
		return
	_compiling = Thread.new()
	_compiling.start(_build.bind(new_score, against if against != null else conductor.ensemble))
	while _compiling.is_alive():
		await get_tree().process_frame
	_plan = _compiling.wait_to_finish()
	_compiling = null
	if not _plan["said"].is_empty():
		if _saying != null:
			_saying.wait_to_finish()
		_saying = Thread.new()
		_saying.start(_say_all.bind(_plan["said"]))


# Every articulation the prepared piece switches each part to, at any
# intensity and on every pass of the loop: ensemble part -> Array of names.
# A part that never switches is absent. What SfzConductor.load_ensemble()
# is given, so the layers load no articulation this piece never plays.
func articulations() -> Dictionary:
	var found := {}
	if _plan.is_empty():
		push_error("ScorePlayer: articulations() before prepare()")
		return found
	for event: Dictionary in _planned():
		if event["kind"] != "art":
			continue
		var arts: Array = found.get_or_add(_planned_cast(event["part"]), [])
		if not arts.has(event["art"]):
			arts.append(event["art"])
	return found


# Every key the prepared piece presses on each part, at any intensity and on
# every pass of the loop: ensemble part -> {"keys": Array of keys as the score
# writes them, "drums": Array of drum names}. A part that plays nothing is
# absent. What SfzConductor.load_ensemble() is given beside articulations(),
# so the layers load no sample this piece never plays.
func played() -> Dictionary:
	var found := {}
	if _plan.is_empty():
		push_error("ScorePlayer: played() before prepare()")
		return found
	for event: Dictionary in _planned():
		var kind: String = event["kind"]
		if kind != "note" and kind != "hit":
			continue
		var part_name := _planned_cast(event["part"])
		if part_name == "":
			continue
		var plays: Dictionary = found.get_or_add(part_name, {"keys": [], "drums": []})
		var list: Array = plays["keys"] if kind == "note" else plays["drums"]
		var what: Variant = int(event["key"]) if kind == "note" else event["drum"]
		if not list.has(what):
			list.append(what)
	return found


# Every event of the prepared piece: head, tail and each body.
func _planned() -> Array:
	var events: Array = _plan["head"] + _plan["tail"]
	for body: Array in _plan["bodies"]:
		events.append_array(body)
	return events


# _cast_of() for the prepared piece, which may not be installed yet.
func _planned_cast(part_name: String) -> String:
	var cast: Dictionary = _plan["cast"]
	return cast[part_name]["part"] if cast.has(part_name) else part_name


# Conductor time the piece's first downbeat is at - or would have been,
# started partway in.
func origin() -> float:
	return _origin


# Conductor time the first thing heard is at: the top, or the bar it was
# started from.
func downbeat() -> float:
	return _origin + _from


# Seconds into the piece it was started from.
func started_from() -> float:
	return _from


func stop() -> void:
	if not SfzConductor._on_main("SfzScorePlayer.stop"):
		return
	_playing = false
	set_process(false)
	# Every note already pressed still gets its release, or it would hang.
	while not _offs.is_empty():
		_release(_offs.pop_front())
	_parts.clear()
	_head = []
	_bodies = []
	_tail = []


# Moves the piece to intensity `level`, and says when, in seconds from the
# top. Lanes written `layer:N` play only at the levels they name; the rest of
# the piece plays at every level. The change lands:
#
#   "now"      as soon as it can - the first moment nothing has been sent past
#   "beat"     on the next beat after that
#   "bar"      on the next barline, which is how a band takes it
#   "section"  at the next section boundary
#
# At the change, lanes leaving the level let go of what they are holding, and
# lanes joining it come in with the notes they would be holding there (bar
# those with less than CATCH left), at the dynamics and articulation they
# would have had. A later call replaces a change that has not landed yet if
# it lands no later. Before anything is sent, it sets the level the piece
# starts at. A landing not in LANDINGS, or a level below 0, is an error:
# nothing changes and it returns -1.
func set_intensity(level: int, at: String = "bar") -> float:
	if not SfzConductor._on_main("SfzScorePlayer.set_intensity"):
		return -1.0
	if not LANDINGS.has(at):
		push_error("ScorePlayer: no landing called '%s' (%s)" % [at, ", ".join(LANDINGS)])
		return -1.0
	if level < 0:
		push_error("ScorePlayer: intensity %d is below 0" % level)
		return -1.0
	if score == null or _horizon == -INF:
		intensity = level
		_levels = [[-INF, level]]
		return 0.0
	var earliest := maxf(_horizon, _from) + _lead_in + 0.05 + LAYER_EARLY
	var when := earliest if at == "now" else _next_boundary(at, earliest)
	_change_level(when, level)
	return when


# The intensity at `t` seconds from the top, as a lane written on the beat
# there hears it.
func intensity_at(t: float) -> int:
	return _level_at(t + LAYER_EARLY)


# Leaves the loop for the outro, and says when, in seconds from the top.
#
#   "pass"     at the end of the pass that is playing: the join the loop was
#              written around, and nothing is cut
#   "section"  at the next section boundary
#   "bar"      at the next barline
#   "beat"     at the next beat - for a handoff that cannot wait for a bar
#   "section:NAME"  where the section NAME next begins, even a pass or more
#              away: the passes up to it play, and the loop is cut there. NAME
#              has to be in the loop; with the loop's first section it is the
#              end of a pass, as "pass" is. A loop limited by `loop_passes`
#              is never made longer: past its last pass this is "pass"
#
# With `outro` false there is no outro: the piece stops at the way out, which
# is how one piece hands over to another on its beat. The notes are let go
# as at a cut and ring off into whatever comes next. A piece without a loop
# can be left that way too, at a bar or a section; with its ending, it is
# already on its way to it, and that is where it ends.
#
# Whatever is inside the scheduling window has already been sent, so the way
# out is the first boundary past it: a bar exit comes between one bar and
# one bar plus the window after the call. At a section or a bar the loop is
# cut CUT_LIFT early, notes still sounding are let go, and the pedal, the
# vibrato and the bend go back to rest, so the outro starts from a clean
# instrument; it was written to follow the end of the loop, and from anywhere
# else it at least follows silence. A pass whose join is already in the window
# has been committed and plays first. Once the way out is decided, calling
# again changes nothing and returns the same time. A way out not in EXITS, or
# a section the loop does not have, is an error: nothing is decided and it
# returns -1.
func leave_loop(at: String = "pass", outro: bool = true, not_before: float = -INF) -> float:
	if not SfzConductor._on_main("SfzScorePlayer.leave_loop"):
		return -1.0
	var why := _exit_error(at)
	if why != "":
		push_error(why)
		return -1.0
	if score == null:
		return -1.0
	if _decided:
		return _exit
	if _leaving:
		return _loop_end + (_passes - 1) * _loop_length
	var exit := peek_exit(at, outro, not_before)
	if not score.has_loop():
		if exit < _end:
			_cut(exit, false)
		_decided = true
		_exit = exit
		return exit
	var join := _loop_end + (_passes - 1) * _loop_length
	if exit > join and exit < INF and at.begins_with("section:"):
		# The section comes round again only in a later pass: the passes up to
		# it are committed now, so the cut below has them to cut. peek_exit()
		# has already kept it inside `loop_passes`.
		while _loop_end + (_passes - 1) * _loop_length < exit:
			_add_pass()
		join = _loop_end + (_passes - 1) * _loop_length
	if exit < join:
		_cut(exit, outro)
		return exit
	_leaving = true
	_bare = not outro
	return join


# When leave_loop(`at`, `outro`) would leave, without leaving: a caller in a
# hurry can see how long a way out takes and pick a sooner one. Seconds from
# the top; -1 with nothing to leave. `not_before` pushes the way out to the
# first boundary at or after that time - to keep playing under a crossfade.
func peek_exit(at: String = "pass", outro: bool = true, not_before: float = -INF) -> float:
	var why := _exit_error(at)
	if why != "":
		push_error(why)
		return -1.0
	if score == null:
		return -1.0
	if _decided:
		return _exit
	if _leaving:
		return _loop_end + (_passes - 1) * _loop_length
	var earliest := maxf(maxf(_horizon, 0.0) + _lead_in + 0.05, not_before)
	if not score.has_loop():
		if outro or at == "pass":
			return _end
		return minf(_next_mark(at, earliest), _end)
	var join := _loop_end + (_passes - 1) * _loop_length
	if at == "pass":
		return join
	if at.begins_with("section:"):
		return minf(_next_mark(at, earliest), _last_join())
	return minf(_next_mark(at, earliest), join)


# The join after the last pass the loop will play unless it is left: after
# pass `loop_passes`, or INF while it can go round again.
func _last_join() -> float:
	if loop_passes <= 0:
		return INF
	return _loop_end + (maxi(_passes, loop_passes) - 1) * _loop_length


# Why `at` is not a way out, or "" when it is.
func _exit_error(at: String) -> String:
	if at.begins_with("section:") and score != null:
		var why := _section_error(at)
		if why == "" and score.has_loop() and not _marks.has(at):
			why = "ScorePlayer: section '%s' is not in the loop" % at.substr(8)
		return why
	if EXITS.has(at) or at.begins_with("section:"):
		return ""
	return "ScorePlayer: no way out called '%s' (%s, section:NAME)" % [at, ", ".join(EXITS)]


# Why "section:NAME" names no section the piece plays, or "" when it does.
func _section_error(kind: String) -> String:
	var name := kind.substr(8)
	if score.order.has(name):
		return ""
	return "ScorePlayer: no section called '%s' in the order (%s)" % [name,
		", ".join(score.order)]


# The first boundary of `kind` at or after `after`, in seconds from the top
# (piece time; after defaults to position()). It looks across the whole
# piece as it will play: the intro, every pass of the loop, and the outro
# once the way out is decided, laid from that way out - or, for a loop set to
# `loop_passes`, from the end of its last pass until it is left sooner.
#
#   "beat", "bar", "section"   the next one of those
#   "section:NAME"             where the section NAME next begins
#   "end"                      where the music ends: the end of the outro, or
#                              the way out when there is no outro
#
# INF when there is none: past the end, or "end" while the loop can still go
# round again (never, with `loop_passes` set). An unknown kind, or a section the order does not play, is an
# error, and returns NAN. It is not
# clamped to what can still be scheduled: a boundary sooner than
# conductor.now() + conductor.lead() - origin() can no longer be acted on.
func next_boundary(kind: String, after: float = position()) -> float:
	if not BOUNDARIES.has(kind) and not kind.begins_with("section:"):
		push_error("ScorePlayer: no boundary called '%s' (%s, section:NAME)"
			% [kind, ", ".join(BOUNDARIES)])
		return NAN
	if score == null:
		return INF
	if kind.begins_with("section:"):
		var why := _section_error(kind)
		if why != "":
			push_error(why)
			return NAN
	var end := length() if score.has_loop() else _end
	if end == INF and score.has_loop() and loop_passes > 0:
		# Not decided yet, but the loop cannot go round past `loop_passes`.
		end = score.duration() + (maxi(_passes, loop_passes) - 1) * _loop_length
	if kind == "end":
		return end if end >= after else INF
	var line := score.timeline()
	if not score.has_loop():
		return _first_in(line, 0, line.size(), 0.0, kind, after, end)
	# The intro.
	var found := _first_in(line, 0, score.loop_from, 0.0, kind, after, end)
	if found < INF:
		return found
	# The loop, up to the way out once there is one. Every pass has the same
	# boundaries, so what is not in the pass `after` falls in or the next is
	# in none of them.
	var exit := INF
	if _decided:
		exit = _exit
	elif _leaving:
		exit = _loop_end + (_passes - 1) * _loop_length
	else:
		exit = _last_join()
	var first := maxi(0, floori((after - _loop_start) / _loop_length))
	for p in range(first, first + 2):
		found = _first_in(line, score.loop_from, score.loop_to, p * _loop_length,
			kind, after, minf(exit, end))
		if found < INF:
			return found
	if exit == INF or end <= exit:
		return INF
	# The outro, laid from the way out.
	return _first_in(line, score.loop_to, line.size(), exit - _loop_end, kind, after, end)


# The first boundary of `kind` at or after `after` and before `before`, in the
# timeline's entries from `first` to before `last`, moved on by `offset`.
func _first_in(line: Array, first: int, last: int, offset: float, kind: String,
		after: float, before: float) -> float:
	var named := kind.substr(8) if kind.begins_with("section:") else ""
	for i in range(first, last):
		var at := float(line[i]["at"]) + offset
		if at >= before:
			return INF
		if named != "" and line[i]["name"] != named:
			continue
		var section: SfzScore.Section = score.sections[line[i]["name"]]
		var step := 60.0 / float(line[i]["bpm"])
		var count := section.bars * score.beats_per_bar
		if kind.begins_with("section"):
			count = 1
		elif kind == "bar":
			step *= score.beats_per_bar
			count = section.bars
		for k in count:
			var t := at + k * step
			if t >= before:
				return INF
			if t >= after:
				return t
	return INF


# Which pass of the loop is committed: 1 during the first. 0 without a loop.
func loop_pass() -> int:
	return _passes


# Seconds of music from the top to the end of the outro, once the way out is
# decided; INF while the loop can still go round again.
func length() -> float:
	if _closed:
		return _end
	if _leaving:
		var join := _loop_end + (_passes - 1) * _loop_length
		return join if _bare else score.duration() + (_passes - 1) * _loop_length
	return INF


# Freed mid-prepare() - the game quitting, a preload dropped - the awaiting
# prepare() is dropped with it, and the thread would run on into a script
# already torn down.
func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	if _compiling != null:
		_compiling.wait_to_finish()
	if _saying != null:
		_saying.wait_to_finish()


func _process(_delta: float) -> void:
	if not _playing:
		return

	_pump(conductor.now() + window - _origin)

	# The tail: the last note still has to ring out, and the longest release
	# on the roster is a couple of seconds.
	if _closed and _parts.is_empty() and _offs.is_empty() \
			and conductor.now() > _origin + _end + 2.0:
		_playing = false
		set_process(false)
		finished.emit()


# --- The plan -------------------------------------------------------------

# Compiles `new_score` and installs it: what play_at() does with a score
# prepare() has not built, and what an offline render and the tests call.
func _prepare(new_score: SfzScore) -> void:
	var plan := _build(new_score, conductor.ensemble)
	_say_all(plan["said"])
	_install(plan)


# Everything compiling `new_score` produces, as a Dictionary nothing else
# holds. It reads the score and never writes to it, and touches no state of
# this player's - prepare() runs it on a worker thread while this player may
# still be playing another piece, and a score is a plain object any number of
# players can hold at once. Only the compiler, which is this player's own and
# is used nowhere else, is set up for the run.
func _build(new_score: SfzScore, against: SfzEnsemble) -> Dictionary:
	compiler.ensemble = against
	var plan := {"score": new_score, "head": [], "bodies": [] as Array[Array],
		"tail": [], "loop_length": 0.0, "loop_end": 0.0, "lead_in": 0.0,
		"loop_start": 0.0, "end": INF, "marks": {}, "intro_marks": {}, "unmapped": {}, "findings": {}, "said": [],
		"ensemble": "" if against == null else against.id,
		"cast": {} if against == null else against.cast(new_score.parts)}

	if not new_score.has_loop():
		var events := compiler.compile(new_score)
		plan["head"] = events
		plan.merge(_report(new_score, events, against), true)
		plan["end"] = new_score.duration()
		plan["marks"] = _marks_of(new_score, 0, new_score.order.size())
		return plan

	var loop_length := new_score.loop_length()
	var loop_end := new_score.loop_end()
	var n := new_score.loop_to - new_score.loop_from
	var written := new_score.order
	# The loop written out once per variation after the copy the intro runs
	# into, so every one of them was performed coming out of a pass rather
	# than out of the intro, and the compiler is told which time round each
	# copy is. It is compiled from a copy of the score with that order: the
	# score itself is never changed, even for a moment, because another
	# player may be reading it.
	var again: Array[String] = []
	again.append_array(written.slice(0, new_score.loop_to))
	for _k in loop_variations:
		again.append_array(written.slice(new_score.loop_from, new_score.loop_to))
	again.append_array(written.slice(new_score.loop_to))
	var passes := PackedInt32Array()
	passes.resize(again.size())
	# The intro and the first pass are round 0. Tested before dividing: a
	# negative offset truncates toward zero, which once put all but the first
	# section of the first pass in round 1, so pass 2 replayed it.
	for at in again.size():
		if at < new_score.loop_to:
			passes[at] = 0
		else:
			passes[at] = mini((at - new_score.loop_to) / n + 1, loop_variations)
	var was := compiler.pass_of
	compiler.pass_of = passes
	var events := compiler.compile(_with_order(new_score, again))
	compiler.pass_of = was
	plan.merge(_report(new_score, events, against), true)

	var head: Array = []
	var bodies: Array[Array] = []
	var tail: Array = []
	bodies.resize(loop_variations)
	for k in loop_variations:
		bodies[k] = []
	for event: Dictionary in events:
		var at: int = event["section"]
		if at < new_score.loop_to:
			head.append(event)
		elif at < new_score.loop_to + n * loop_variations:
			bodies[(at - new_score.loop_to) / n].append(event)
		else:
			tail.append(event)

	# Setup points, keyswitches and pushed notes fall a little before their
	# section; a pass or the outro has to be committed before the earliest.
	# Body k starts a further loop length on from where the first pass ends,
	# and the tail follows the last of them.
	var lead_in := 0.0
	for k in bodies.size():
		if not bodies[k].is_empty():
			lead_in = maxf(lead_in, loop_end + k * loop_length - float(bodies[k][0]["t"]))
	if not tail.is_empty():
		lead_in = maxf(lead_in, loop_end + loop_variations * loop_length
				- float(tail[0]["t"]))

	plan["head"] = head
	plan["bodies"] = bodies
	plan["tail"] = tail
	plan["loop_length"] = loop_length
	plan["loop_end"] = loop_end
	plan["lead_in"] = lead_in
	# The boundaries a loop can be left at, in the first pass; later passes
	# are the same a loop length on.
	plan["loop_start"] = float(new_score.timeline()[new_score.loop_from]["at"])
	plan["marks"] = _marks_of(new_score, new_score.loop_from, new_score.loop_to)
	# The intro plays once, so its boundaries are not a loop length apart:
	# kept apart, and only the plain kinds - "section:NAME" names the loop.
	var intro := _marks_of(new_score, 0, new_score.loop_from)
	plan["intro_marks"] = {"section": intro["section"], "bar": intro["bar"], "beat": intro["beat"]}
	return plan


# A shallow copy of `source` playing `order`: the sections and lanes are the
# same objects, only the order is its own.
static func _with_order(source: SfzScore, order: Array[String]) -> SfzScore:
	var copy := SfzScore.new()
	for property: Dictionary in copy.get_property_list():
		if property["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE:
			copy.set(property["name"], source.get(property["name"]))
	copy.order = order
	return copy


# Makes `plan` (from _build()) this player's piece, from the top. Main thread.
func _install(plan: Dictionary) -> void:
	score = plan["score"]
	_head = plan["head"]
	_bodies = plan["bodies"]
	_tail = plan["tail"]
	_loop_length = plan["loop_length"]
	_loop_end = plan["loop_end"]
	_lead_in = plan["lead_in"]
	_loop_start = plan["loop_start"]
	_marks = plan["marks"]
	_intro_marks = plan["intro_marks"]
	_unmapped = plan["unmapped"]
	_findings = plan["findings"]
	_cast = plan["cast"]
	_count = 0
	_leaving = false
	_bare = false
	_decided = false
	_horizon = -INF
	_offs = []
	_sounding = []
	_seq = 0
	_cc_last = {}
	_from = 0.0
	_levels = [[-INF, intensity]]
	_held_notes = []
	_held_state = {}
	_parts = [{"events": _head, "next": 0, "offset": 0.0}]
	if score.has_loop():
		_passes = 1
		_closed = false
		_end = INF
		_exit = INF
	else:
		_passes = 0
		_closed = true
		_end = plan["end"]
		_exit = _end


# What this ensemble cannot play of this score as written, said once per (ensemble,
# score, part, item), here, at prepare, so tools/check.gd and an offline
# render hear about it before anything plays rather than never (the
# per-ensemble warnings, GOALS §6). Three sources:
#
#   the cast      a score part the ensemble has no part of that name for, and
#                 where it landed instead (docs/REGISTRY.md §6) - unless it
#                 has no notes, or is a co-part playing with its player
#   the plan      each event asked what the conductor will ask of the part it
#                 is cast on: a drum the kit has no key for, a keyswitch no
#                 layer answers, a control no layer reads, a note outside
#                 the part's range (folded by octaves, not dropped) or
#                 outside every layer's velocity window
#   the compiler  what it played some other way and so left out of the plan
#                 (SfzScoreCompiler.fell_back): a mute with no mute key, a
#                 ramp with no dynamics control, a bend on the pitch wheel
#
# Nothing here changes what plays. A drum the kit lacks is still skipped - a
# kit with no ride sits the ride out, and thinning out is the design - only
# the report is new. A part cast on nothing says that and nothing else about
# itself; everything else it would have said is part of it.
#
# Returns {unmapped, findings, said} for the plan (see _unmapped and
# _findings; `said` is the texts of the findings no player has said yet in
# this run, for prepare() or _prepare() to say) and sets nothing of this
# player's: _build() calls it, on prepare()'s worker while another piece may
# still be playing, and _install() takes them.
func _report(for_score: SfzScore, events: Array, ensemble: SfzEnsemble) -> Dictionary:
	var unmapped := {}
	var findings := {}
	var said: Array = []
	var result := {"unmapped": unmapped, "findings": findings, "said": said}
	if ensemble == null:
		return result
	var cast := ensemble.cast(for_score.parts)
	var found := {}
	for event: Dictionary in events:
		var part_name: String = event["part"]
		var cast_as: Dictionary = cast.get(part_name, {"part": part_name, "step": 1})
		var part := ensemble.part(cast_as["part"])
		var kind: String = event["kind"]
		var step := int(cast_as["step"])
		if step > 1:
			# One finding per part cast past its own name, co-parts
			# included, with the part it landed on; counted so a part with
			# no notes can stay quiet.
			var moved := _finding(found, part_name, "cast")
			moved["cast"] = cast_as["part"]
			moved["step"] = step
			moved["family"] = for_score.parts.get(part_name, {}).get("family", part_name)
			if part.layers.is_empty():
				moved["dropped"] += 1
			if kind == "note" or kind == "hit":
				moved["notes"] += 1
		if part.layers.is_empty():
			continue
		var perf: String = event.get("perf", part_name)
		match kind:
			"hit":
				var drum: String = event["drum"]
				if part.key_for(drum) < 0:
					unmapped["%s|%s" % [part_name, drum]] = true
					var missing := _finding(found, part_name, "drum")
					missing["dropped"] += 1
					if not drum in missing["names"]:
						missing["names"].append(drum)
				elif not _taken(part, int(event["velocity"])):
					_finding(found, part_name, "velocity")["dropped"] += 1
			"note":
				if not part.covers(int(event["key"])):
					_finding(found, part_name, "fit")["count"] += 1
				if not _taken(part, int(event["velocity"])):
					_finding(found, part_name, "velocity")["dropped"] += 1
			"art":
				if not part.switches(event["art"]):
					_lane_of(_finding(found, part_name, "art:" + event["art"]),
						perf)["dropped"] += 1
			"cc":
				if not part.hears(event["control"]):
					_lane_of(_finding(found, part_name, "control:" + event["control"]),
						perf)["dropped"] += 1
	if compiler != null:
		for entry: Dictionary in compiler.fell_back.values():
			var cast_as: Dictionary = cast.get(entry["part"], {"part": entry["part"]})
			if ensemble.part(cast_as["part"]).layers.is_empty():
				continue
			var f := _finding(found, entry["part"], entry["item"])
			f["count"] += int(entry["count"])
			f["fallback"] = entry["fallback"]
			for lane: String in entry.get("lanes", []):
				if not lane in f["lanes"]:
					f["lanes"].append(lane)

	var who := for_score.id if for_score.id != "" else for_score.title
	var keys := found.keys()
	keys.sort()
	for key: String in keys:
		var f: Dictionary = found[key]
		if f["item"] == "cast" and int(f["notes"]) == 0:
			continue
		var text := _finding_text(who, ensemble, f,
			cast.get(f["part"], {"part": f["part"]})["part"])
		findings[key] = {"part": f["part"], "item": f["item"], "text": text,
			"dropped": f["dropped"]}
		var record := "%s|%s|%s" % [ensemble.id, who, key]
		_reported_mutex.lock()
		var fresh := not _reported.has(record)
		_reported[record] = true
		_reported_mutex.unlock()
		if fresh:
			said.append(text)
	return result


func _say_all(texts: Array) -> void:
	for text: String in texts:
		_say(text)


# Says one finding. push_warning, on prepare()'s saying thread, or the
# caller's for _prepare(); a tool that prints the findings itself
# (tools/check.gd) overrides it to keep quiet.
func _say(text: String) -> void:
	push_warning(text)


func _finding(found: Dictionary, part: String, item: String) -> Dictionary:
	var key := "%s|%s" % [part, item]
	if not found.has(key):
		found[key] = {"part": part, "item": item, "dropped": 0, "count": 0,
			"notes": 0, "fallback": "", "names": [], "lanes": [], "cast": "",
			"step": 1, "family": ""}
	return found[key]


# Notes which lane a finding came from, by performance name.
static func _lane_of(f: Dictionary, lane: String) -> Dictionary:
	if not lane in f["lanes"]:
		f["lanes"].append(lane)
	return f


# Whether any of the part's layers plays this velocity: the conductor's
# Layer.takes, which is velocity layering when some layers do and others do
# not, and a dropped note when none does.
static func _taken(part: SfzEnsemble.Part, velocity: int) -> bool:
	for layer: SfzEnsemble.Layer in part.layers:
		if layer.takes(velocity):
			return true
	return false


# What each resolution step is called in a warning (SfzEnsemble.resolve).
const STEP_WORDS := {2: "family default", 3: "its player's part", 4: "family fallback",
	5: "nothing plays it"}


# One finding in words: the score, the part, what it lacks in which ensemble,
# and what happens instead. Counts are of events in the compiled plan (a
# loop counts once per copy the player compiles). `cast_as` is the ensemble
# part the score part plays on.
func _finding_text(who: String, ensemble: SfzEnsemble, f: Dictionary, cast_as: String) -> String:
	var part_name: String = f["part"]
	var part := ensemble.part(cast_as)
	var item: String = f["item"]
	var name := item.get_slice(":", 1)
	var times := int(f["dropped"]) + int(f["count"])
	var count := "(%d time%s)" % [times, "" if times == 1 else "s"]
	var names: Array = f["names"]
	names.sort()
	# Who lacks it: the part, or the lanes the question was asked for when
	# only some of the part's lanes do.
	var lanes: Array = f["lanes"]
	lanes.sort()
	var subject := part_name if lanes.is_empty() or part_name in lanes else ", ".join(lanes)
	match item.get_slice(":", 0):
		"cast":
			var head := "%s: part '%s' (%s): not in ensemble %s" % [
				who, part_name, f["family"], ensemble.id]
			if f["cast"] == "":
				return "%s; nothing plays it, and its %d notes sit out" % [head, f["notes"]]
			return "%s; plays %s (%s)" % [head, f["cast"], STEP_WORDS.get(int(f["step"]), "")]
		"drum":
			var drums: Array = []
			for drum: String in names:
				drums.append("'%s'" % drum)
			return "%s: %s has no %s in ensemble %s; those hits sit out" % [
				who, part_name, ", ".join(drums), ensemble.id]
		"art":
			var art_instead: String = f["fallback"]
			if art_instead == "":
				art_instead = SfzScoreCompiler.KEEPS_ART
			return "%s: %s %s no '%s' articulation in ensemble %s; %s %s" % [
				who, subject, "have" if lanes.size() > 1 and not part_name in lanes else "has",
				name, ensemble.id, art_instead, count]
		"clash":
			return "%s: %s switch%s %s to '%s' %s %s" % [
				who, subject, "" if lanes.size() > 1 and not part_name in lanes else "es",
				part_name, name, f["fallback"], count]
		"control":
			var control_instead: String = f["fallback"]
			if control_instead == "":
				control_instead = "those messages reach nothing"
			return "%s: %s %s no '%s' control in ensemble %s; %s %s" % [
				who, subject, "have" if lanes.size() > 1 and not part_name in lanes else "has",
				name, ensemble.id, control_instead, count]
		"fit":
			return "%s: %d %s notes lie outside ensemble %s's range for it (%d to %d); moved by octaves into it" % [
				who, times, part_name, ensemble.id, part.lokey, part.hikey]
		"velocity":
			return "%s: %d %s notes and hits are outside every playing layer's velocity range in ensemble %s; they sit out" % [
				who, times, part_name, ensemble.id]
	return "%s: %s, %s, in ensemble %s %s" % [who, part_name, item, ensemble.id, count]


# The section, bar and beat boundaries of the sections from `first` to before
# `last` in `of`'s order, in seconds from the top, and each named section's own
# downbeats under "section:NAME".
static func _marks_of(of: SfzScore, first: int, last: int) -> Dictionary:
	var line := of.timeline()
	var marks := {"section": [], "bar": [], "beat": []}
	for i in range(first, last):
		var entry: Dictionary = line[i]
		var section: SfzScore.Section = of.sections[entry["name"]]
		var beat := 60.0 / float(entry["bpm"])
		marks["section"].append(float(entry["at"]))
		var named := "section:%s" % entry["name"]
		if not marks.has(named):
			marks[named] = []
		marks[named].append(float(entry["at"]))
		for k in section.bars * of.beats_per_bar:
			if k % of.beats_per_bar == 0:
				marks["bar"].append(float(entry["at"]) + k * beat)
			marks["beat"].append(float(entry["at"]) + k * beat)
	return marks


# Where a start `from` seconds in actually starts: the barline at or before
# it, in the first pass if it is past that. Past the end of a piece that
# does not loop is the top again.
func _seek_point(from: float) -> float:
	if from <= 0.0:
		return 0.0
	if score.has_loop():
		if from >= _loop_end:
			from = _loop_start + fposmod(from - _loop_start, _loop_length)
	elif from >= _end:
		return 0.0
	var bar := 0.0
	for entry: Dictionary in score.timeline():
		var at := float(entry["at"])
		if at > from:
			break
		var section: SfzScore.Section = score.sections[entry["name"]]
		var length := 60.0 / float(entry["bpm"]) * score.beats_per_bar
		bar = at + floorf(minf((from - at) / length, section.bars - 1)) * length
	return bar


# Commits whatever follows the last committed pass, once its join is close
# enough that the decision cannot wait: another pass, unless the loop has
# been left or has played its count, and otherwise the outro.
func _commit(horizon: float) -> void:
	while not _closed:
		# The join after pass `_passes`, in seconds from the top.
		var join := _loop_end + (_passes - 1) * _loop_length
		if horizon < join - _lead_in - 0.05:
			return
		var again := not _leaving and (loop_passes <= 0 or _passes < loop_passes)
		if again:
			_add_pass()
		elif _bare:
			# No outro: the pass is the last thing, and it ends at the join.
			_closed = true
			_decided = true
			_exit = join
			_end = join
		else:
			# _tail is timed as if it followed the last variation.
			var offset := (_passes - 1 - _bodies.size()) * _loop_length
			_parts.append({"events": _tail, "next": 0, "offset": offset})
			_closed = true
			_decided = true
			_exit = join
			_end = score.duration() + (_passes - 1) * _loop_length


# Commits the next pass of the loop. Round the variations and back to the
# first: body k is timed as the (k + 2)th pass, so playing it as pass
# _passes + 1 moves it by the difference.
func _add_pass() -> void:
	var k := (_passes - 1) % _bodies.size()
	_parts.append({"events": _bodies[k], "next": 0,
		"offset": (_passes - 1 - k) * _loop_length})
	_passes += 1


# The first boundary of this kind at or after `earliest`, in any pass.
func _next_mark(kind: String, earliest: float) -> float:
	var marks: Array = _marks.get(kind, [])
	if marks.is_empty():
		return INF
	if not score.has_loop():
		for m in marks:
			if float(m) >= earliest:
				return float(m)
		return INF
	# Still in the intro: a game that cannot wait for the loop leaves from it.
	for m in _intro_marks.get(kind, []):
		if float(m) >= earliest:
			return float(m)
	var p := maxi(0, floori((earliest - _loop_start) / _loop_length))
	while true:
		for m in marks:
			var t: float = float(m) + p * _loop_length
			if t >= earliest:
				return t
		p += 1
	return INF


# Ends the loop at `exit`, mid-pass. Everything playing stops CUT_LIFT
# before it - releases moved up, the rest of the pass dropped - a marker at
# that moment puts the controls back to rest, and the outro, if there is to
# be one, is laid so that its first downbeat is `exit`. The window that decided this has already been
# sent, and `exit` was chosen to be past it, so nothing here needs taking back.
func _cut(exit: float, outro: bool = true) -> void:
	var stop := exit - CUT_LIFT
	for part: Dictionary in _parts:
		part["stop"] = minf(float(part.get("stop", INF)), stop)
	for off: Dictionary in _offs:
		off["end"] = _clamped(off)
	_offs.sort_custom(_sooner)
	_parts.append({"events": [{"kind": "rest", "t": stop}], "next": 0, "offset": 0.0})
	for item: Dictionary in _sounding:
		if float(item["note_end"]) > stop:
			var early := item.duplicate()
			early["event"] = (item["event"] as Dictionary).duplicate()
			early["end"] = _clamped(item)
			_release(early)
	_sounding = []
	_closed = true
	_decided = true
	_exit = exit
	if not outro:
		_end = exit
		return
	# _tail is timed as if it followed the last variation.
	_parts.append({"events": _tail, "next": 0,
		"offset": exit - (_loop_end + _bodies.size() * _loop_length)})
	_end = exit + score.duration() - _loop_end


# Hands out every event up to `horizon` (seconds from the top), earliest
# first across the parts that are playing. Two events at the same instant go
# in the order their parts were committed, so the end of one pass is always
# dispatched before the start of the next - the next section's setup has to
# be the last word, as it is between any two sections.
#
# A release goes out just before the first event that is not earlier than it,
# which puts it exactly where it sat when a note's release was sent with its
# press: after everything before it, and ahead of a new press at the same
# instant.
func _pump(horizon: float) -> void:
	_horizon = maxf(_horizon, horizon)
	_commit(horizon)
	while true:
		var best := -1
		var best_at := INF
		for k in _parts.size():
			var part: Dictionary = _parts[k]
			var events: Array = part["events"]
			var i: int = part["next"]
			if i >= events.size():
				continue
			var at: float = float(events[i]["t"]) + float(part["offset"])
			if at >= float(part.get("stop", INF)):
				# Cut: the rest of this part never plays.
				part["next"] = events.size()
				continue
			if at < best_at:
				best = k
				best_at = at
		if not _offs.is_empty() and float(_offs[0]["end"]) <= minf(best_at, horizon):
			_release(_offs.pop_front())
			continue
		if best < 0 or best_at > horizon:
			break
		var part: Dictionary = _parts[best]
		var event: Dictionary = part["events"][part["next"]]
		part["next"] = int(part["next"]) + 1
		_send(event, part, best_at)

	# Releases already past cannot be cut short any more.
	if not _sounding.is_empty():
		_sounding = _sounding.filter(func(item: Dictionary) -> bool:
			return float(item["note_end"]) >= _horizon)

	if not _held_notes.is_empty():
		_held_notes = _held_notes.filter(func(item: Dictionary) -> bool:
			return float(item["end"]) >= _horizon)

	# Parts that are done are dropped, so a loop can run for hours.
	var live: Array = []
	for part: Dictionary in _parts:
		if int(part["next"]) < (part["events"] as Array).size():
			live.append(part)
	_parts = live


# One compiled event, at `at` seconds from the top.
func _send(event: Dictionary, part: Dictionary, at: float) -> void:
	if at < _from:
		var placed := at >= _from - PLACED_EARLY
		match event["kind"]:
			"note":
				var left := at + float(event["duration"]) - _from
				if left <= 0.0 or (left < CATCH and not placed):
					return
				event = event.duplicate()
				event["duration"] = left
				at = _from
			"cc", "art":
				at = _from
			"hit":
				if not placed:
					return
				at = _from
			_:
				return
	if event.has("layer") and not _in_layer(event, _level_at(at + LAYER_EARLY)):
		_hold_back(event, at)
		return
	_take_at = at
	match event["kind"]:
		"rest":
			_rest(at)
			return
		"layers":
			_land(at)
			return
		"note":
			_dispatch(event, _origin + at)
			var off := event.duplicate()
			off["kind"] = "off"
			off["at"] = _origin + at
			_seq += 1
			var item := {"event": off, "start": at, "part": part, "seq": _seq,
				"note_end": at + float(event["duration"])}
			item["end"] = _clamped(item)
			# A release no cut can reach any more goes out with its press, as a
			# whole note's does - the renderer orders two events on the same
			# sample by arrival, so this keeps every such tie where it was.
			# Only a piece that can still be cut holds releases back, and only
			# those that end beyond the nearest point a cut could still land.
			if _decided or not score.has_loop() 					or float(item["end"]) <= _horizon + _lead_in + 0.05 - CUT_LIFT:
				if not _decided and not score.has_loop():
					_sounding.append(item)
				_release(item)
				_count += 1
				return
			var i := _offs.size()
			while i > 0 and _sooner(item, _offs[i - 1]):
				i -= 1
			_offs.insert(i, item)
		"cc":
			_dispatch(event, _origin + at)
			var key := "%s|%s" % [event["part"], event["control"]]
			_cc_last[key] = event
			_held_state.erase(key)
		"art":
			_dispatch(event, _origin + at)
			_held_state.erase("%s|art" % event["part"])
		_:
			_dispatch(event, _origin + at)
	_count += 1


func _release(item: Dictionary) -> void:
	var off: Dictionary = item["event"]
	# Only a moved release is re-measured: the written one goes out with the
	# duration it was compiled with, to the bit.
	if float(item["end"]) < float(item["note_end"]):
		off["duration"] = float(item["end"]) - float(item["start"])
	_take_at = float(item["start"])
	_dispatch(off, _origin + float(item["end"]))


# A note's release, pulled in to its part's stop if a cut has set one - but
# never to before the note has had a moment to sound.
func _clamped(item: Dictionary) -> float:
	var end: float = item["note_end"]
	var stop := float((item["part"] as Dictionary).get("stop", INF))
	if end <= stop:
		return end
	return maxf(stop, float(item["start"]) + 0.01)


func _sooner(a: Dictionary, b: Dictionary) -> bool:
	return float(a["end"]) < float(b["end"]) \
		or (float(a["end"]) == float(b["end"]) and int(a["seq"]) < int(b["seq"]))


# The controls a cut leaves away from rest, put back.
func _rest(at: float) -> void:
	for key in _cc_last.keys():
		var last: Dictionary = _cc_last[key]
		var rest := _resting(last["part"], last["control"])
		if rest < 0 or int(last["value"]) == rest:
			continue
		var event := {"kind": "cc", "t": at, "part": last["part"],
			"control": last["control"], "value": rest, "perf": last.get("perf", last["part"])}
		_dispatch(event, _origin + at)
		_cc_last[key] = event


# Where a score part's control rests: the default of the part it is cast on.
func _resting(part_name: String, control: String) -> int:
	if conductor != null and conductor.ensemble != null:
		var part := conductor.ensemble.part(_cast_of(part_name))
		if part.defaults.has(control):
			return int(part.defaults[control])
	return int(RESTING.get(control, -1))


# The ensemble part the score part `part_name` is cast on; the name itself
# for a part the cast does not know (a plan built with no ensemble).
func _cast_of(part_name: String) -> String:
	if _cast.has(part_name):
		return _cast[part_name]["part"]
	return part_name


func _dispatch(event: Dictionary, at: float) -> void:
	var part_name := _cast_of(event["part"])
	# Cast on nothing: reported at prepare, and nothing would hear it.
	if part_name == "":
		return
	match event["kind"]:
		"note":
			conductor.note_on(part_name, event["key"], event["velocity"], at,
				false, _take_at)
		"off":
			conductor.note_off(part_name, event["key"], event["velocity"],
				float(event["at"]), float(event["duration"]), false, _take_at)
		"hit":
			# Reported at prepare; the conductor would skip it too.
			if _unmapped.has("%s|%s" % [event["part"], event["drum"]]):
				return
			conductor.hit(part_name, event["drum"], event["velocity"], at,
				false, _take_at)
		"art":
			conductor.articulate(part_name, event["art"], at)
		"cc":
			conductor.cc(part_name, event["control"], event["value"], at)


# --- Intensity -------------------------------------------------------------

func _in_layer(event: Dictionary, level: int) -> bool:
	var layer: Array = event["layer"]
	return level >= int(layer[0]) and level <= int(layer[1])


func _level_at(t: float) -> int:
	for i in range(_levels.size() - 1, -1, -1):
		if float(_levels[i][0]) <= t:
			return int(_levels[i][1])
	return intensity


# A change to `level` at `when`. Any change still to come at or after it is
# superseded; the event that would have landed it finds nothing to do.
func _change_level(when: float, level: int) -> void:
	while _levels.size() > 1 and float(_levels[-1][0]) >= when:
		_levels.pop_back()
	# Changes long past are kept only as far as the one in force.
	while _levels.size() > 1 and float(_levels[1][0]) < _horizon - 10.0:
		_levels.pop_front()
	intensity = level
	if int(_levels[-1][1]) == level:
		return
	_levels.append([when, level])
	_parts.append({"events": [{"kind": "layers", "t": when}], "next": 0, "offset": 0.0})


# What set_intensity() lands on: next_boundary(), or `earliest` itself when
# the piece has no such boundary left.
func _next_boundary(kind: String, earliest: float) -> float:
	var t := next_boundary(kind, earliest)
	return earliest if is_inf(t) else t


# A change landing, at `at` seconds from the top.
func _land(at: float) -> void:
	var before := _level_at(at - 1e-6)
	var after := _level_at(at)
	if before == after:
		return
	# Leaving: what the lane is holding is let go at the boundary.
	for off: Dictionary in _offs:
		var off_event: Dictionary = off["event"]
		if off_event.has("layer") and not _in_layer(off_event, after) \
				and float(off["note_end"]) > at:
			off["note_end"] = maxf(at, float(off["start"]) + 0.01)
			off_event["duration"] = float(off["note_end"]) - float(off["start"])
			off["end"] = _clamped(off)
	_offs.sort_custom(_sooner)
	var still: Array = []
	for item: Dictionary in _sounding:
		var item_event: Dictionary = item["event"]
		if item_event.has("layer") and not _in_layer(item_event, after) \
				and float(item["note_end"]) > at:
			var early := item.duplicate()
			early["event"] = item_event.duplicate()
			early["end"] = maxf(at, float(item["start"]) + 0.01)
			_release(early)
		else:
			still.append(item)
	_sounding = still

	# Joining: controls first, so the notes speak at the level they should.
	var part := {"events": [], "next": 0, "offset": 0.0}
	for key in _held_state.keys():
		var held: Dictionary = _held_state[key]
		if _in_layer(held, after):
			_held_state.erase(key)
			_send(held, part, at)
	var waiting: Array = []
	for item: Dictionary in _held_notes:
		var note: Dictionary = item["event"]
		if not _in_layer(note, after):
			waiting.append(item)
			continue
		var left := float(item["end"]) - at
		if float(item["start"]) < at and left >= CATCH:
			var caught := note.duplicate()
			caught["duration"] = left
			_send(caught, part, at)
	_held_notes = waiting


# An event a silent layer would have sent: kept, for as long as it could still
# matter to the layer coming in.
func _hold_back(event: Dictionary, at: float) -> void:
	match event["kind"]:
		"note":
			_held_notes.append({"event": event, "start": at,
				"end": at + float(event["duration"])})
		"cc":
			_held_state["%s|%s" % [event["part"], event["control"]]] = event
		"art":
			_held_state["%s|art" % event["part"]] = event


# Every event at once, for an offline render.
#
# The streaming above exists because the audio thread's queue is shallow and
# a five minute piece is bigger than it. Offline there is no queue - the
# renderer holds the whole sorted list and walks it - so the window, the lead
# and the tail all drop out and what is left is the same _dispatch() over the
# same compiled events. Returns how many went out.
#
# A loop has to end for that, so it plays `loop_passes` times, or once if that
# is 0; length() then says how long the render has to be. Or, given
# `leave_at`, it plays as a game would that called leave_loop(`leave_how`)
# at that many seconds in, with the window already sent.
func dispatch_all(new_score: SfzScore, leave_at: float = -1.0,
		leave_how: String = "pass", outro: bool = true) -> int:
	if conductor == null or not conductor.is_loaded():
		push_error("ScorePlayer: no ensemble loaded")
		return 0
	var passes := loop_passes
	if passes <= 0 and leave_at < 0.0:
		loop_passes = 1
	if leave_at >= 0.0 and (new_score.has_loop() or not outro):
		dispatch_until(new_score, leave_at)
		leave_loop(leave_how, outro)
	else:
		dispatch_until(new_score, -INF)
	dispatch_rest()
	loop_passes = passes
	return _count


# dispatch_all() in two halves, for a caller that decides the way out itself:
# everything a game would have sent `until` seconds in, with the piece's top
# at `origin` on the renderer's timeline...
func dispatch_until(new_score: SfzScore, until: float, origin: float = 0.0) -> void:
	if conductor == null or not conductor.is_loaded():
		push_error("ScorePlayer: no ensemble loaded")
		return
	_prepare(new_score)
	# Absolute seconds, which is what the renderer means by a time. There is
	# nothing to be late for, so there is no lead.
	_origin = origin
	if until > -INF:
		_pump(until + window)


# ...and then the rest. A loop nobody has left plays `loop_passes` times.
func dispatch_rest() -> int:
	if score != null and score.has_loop() and not _leaving and not _decided 			and loop_passes <= 0:
		loop_passes = 1
	_pump(INF)
	return _count


# Where the loop is left, in seconds from the top, once that is decided.
func exit_time() -> float:
	return _exit


# --- Reporting -----------------------------------------------------------

# Events compiled for the piece; with a loop, the intro, every compiled
# variation of the pass, and the outro.
func event_count() -> int:
	var n := _head.size() + _tail.size()
	for body in _bodies:
		n += body.size()
	return n


# A human-readable plan, for printing before playback so a run can be
# checked against the score without listening to it.
func outline() -> String:
	var lines: Array[String] = []
	for entry in score.timeline():
		var section: SfzScore.Section = score.sections[entry["name"]]
		var parts: Array[String] = []
		for part_name in score.parts:
			var count := 0
			var found := false
			for lane: SfzScore.Lane in section.lanes.values():
				if lane.part == part_name:
					count += lane.events.size()
					found = true
			if found:
				parts.append("%s(%d)" % [part_name, count])
		lines.append("  %-8s %5.1fs  %3d bars @ %.0f bpm  %s" % [
			entry["name"], float(entry["at"]), section.bars,
			float(entry["bpm"]), " ".join(parts)])
	return "\n".join(lines)
