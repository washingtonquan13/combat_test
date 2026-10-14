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
# The whole piece goes to the instruments before it starts. At prepare, every
# compiled event is resolved into the rows each layer's instrument plays
# (SfzTimeline, _resolve()), and at play_at() those rows are uploaded to a
# timeline slot on each instrument, whose cursor plays them on the audio
# thread (native/src/timeline.h). What is left on this side is decisions -
# start, leave the loop, change the intensity, stop - each sent as an op for
# a frame of the piece. A game thread that stalls delays a decision, never a
# note.
#
# Lanes written `layer:N` are intensity layers: the game raises and lowers
# the intensity and they come in and drop out, on a bar, without the piece
# changing under them - see set_intensity(). Nothing is recompiled for it.
# Every lane is resolved as always, each row carrying the levels it plays at,
# and the cursor holds back what is outside the level, so a layer that comes
# in is exactly where it would have been had it played all along.

signal finished


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
# of the piece, and packed (see SfzEventList). Without a loop, everything is
# in _head.
var _head := SfzEventList.new()  # the intro and the loop's first pass
# Later passes of the loop, each performed coming out of the one before,
# each timed as the pass it was compiled as: _bodies[k] sits a further loop
# length on. They are played in order and then from the start again.
var _bodies: Array[SfzEventList] = []
var _tail := SfzEventList.new()  # the outro, timed as if it followed the last body
var _loop_length := 0.0
var _loop_end := 0.0        # where the first pass ends
var _lead_in := 0.0         # how far before a pass its earliest event falls
var _loop_start := 0.0      # where the first pass starts
var _marks := {}            # exit -> its boundaries in the first pass, in seconds
var _intro_marks := {}      # "section", "bar", "beat" -> the intro's own, before the loop

# The cursors' decisions, followed here so the ones still to make are made
# the way the cursor will take them (native/src/timeline.h, TimelineCursor,
# which keeps the same bookkeeping): see _track().
var _passes := 0            # passes of the loop committed, the first included
var _leaving := false
var _bare := false          # leaving without the outro: the piece just stops
var _closed := false        # the outro, or the whole piece, is committed
var _decided := false       # the way out is settled; nothing can be cut now
var _exit := INF            # where the loop is left, once it is decided

# The intensity over time: [seconds from the top, level] pairs, in order,
# the first at -INF. A change is a pair at its boundary.
var _levels: Array = []

# The installed piece resolved for this ensemble: ensemble part -> Array, per
# layer of the part's stack, of interface A timelines ({} for a layer that
# plays nothing). See _resolve().
var _timelines: Dictionary = {}
# The slots the piece is uploaded to, one per layer that plays anything: the
# conductor's records (SfzConductor.claim_timeline()).
var _slots: Array = []
# Between play_at() and the end of its frame the PLAY op is not sent yet, so a
# set_intensity() in the same frame still sets the level the piece starts at,
# as it did when nothing went out before the first _process(). Ops made
# meanwhile wait in _queued, [op, b, when, arg], and go after it.
var _pending := false
var _queued: Array = []
var _play_id := 0

var _origin: float = 0.0    # conductor time the piece starts at
# The playback rate, frames per second: what piece time is counted in once it
# reaches an instrument (SfzTimeline).
var _rate: float = 44100.0
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
	# A piece already playing on this player is let go first, as the old one
	# would have been by the plan it was streamed from being replaced.
	_stop_slots()
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
	_upload()
	_playing = true
	_pending = true
	_queued = []
	_play_id += 1
	# Live, PLAY goes at the end of the frame (see _pending). Offline there are
	# no frames: a render decides everything before it renders a sample.
	if conductor.is_offline():
		_start(_play_id)
	else:
		_start.call_deferred(_play_id)
	set_process(true)
	return true


# The installed piece on every layer that plays anything: a slot claimed and
# the timeline uploaded, the loop's count as it stands now.
func _upload() -> void:
	_slots = []
	for part_name: String in _timelines:
		var stack: Array = conductor._stacks.get(part_name, [])
		var per_layer: Array = _timelines[part_name]
		for li in mini(stack.size(), per_layer.size()):
			var timeline: Dictionary = per_layer[li]
			if timeline.is_empty():
				continue
			timeline["loop_passes"] = maxi(loop_passes, 0)
			var record := conductor.claim_timeline(self, stack[li], timeline, part_name)
			if not record.is_empty():
				_slots.append(record)


# Sends PLAY to every slot of play number `id`, at the piece's top, and then
# whatever was decided before it went.
func _start(id: int) -> void:
	if id != _play_id or not _pending:
		return
	_pending = false
	for record: Dictionary in _slots:
		conductor.decide_timeline(record, SfzTimeline.OP_PLAY, intensity,
			conductor.timeline_frame(record, _origin), _frames(_from))
	var queued := _queued
	_queued = []
	for op: Array in queued:
		_op(op[0], op[1], op[2], op[3])


# One decision to every slot of the piece, or to the queue while PLAY waits.
func _op(op: int, b: int, when: int, arg: int = 0) -> void:
	if _pending:
		_queued.append([op, b, when, arg])
		return
	for record: Dictionary in _slots:
		conductor.decide_timeline(record, op, b, when, arg)


# Lets go of every slot the piece is on: STOP to the ones started (the
# conductor frees each when its cursor says it has ended), the rest given
# back as they are.
func _stop_slots() -> void:
	for record: Dictionary in _slots:
		if _pending:
			conductor.forget_timeline(record)
		else:
			conductor.decide_timeline(record, SfzTimeline.OP_STOP, 0, 0)
	_slots = []
	_pending = false
	_queued = []


# A report from one of this piece's cursors (SfzConductor._poll_timelines()):
# `kind` a SfzTimeline.REPORT_*, `arg` as timeline.h has it.
func _timeline_report(_record: Dictionary, kind: int, _frame: int, arg: int) -> void:
	if kind == SfzTimeline.REPORT_PASS_STARTED and not _closed and not _leaving:
		_passes = maxi(_passes, arg)


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
	for list in _planned():
		for i in list.size():
			if list.kind_at(i) != "art":
				continue
			var event := list.at(i)
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
	for list in _planned():
		for i in list.size():
			var kind := list.kind_at(i)
			if kind != "note" and kind != "hit":
				continue
			_add_played(found, kind, list.at(i))
	return found


# One note or hit of the prepared piece, added to played()'s `found`.
func _add_played(found: Dictionary, kind: String, event: Dictionary) -> void:
	var part_name := _planned_cast(event["part"])
	if part_name == "":
		return
	var plays: Dictionary = found.get_or_add(part_name, {"keys": [], "drums": []})
	var list: Array = plays["keys"] if kind == "note" else plays["drums"]
	var what: Variant = int(event["key"]) if kind == "note" else event["drum"]
	if not list.has(what):
		list.append(what)


# Every part of the prepared piece: head, tail and each body.
func _planned() -> Array[SfzEventList]:
	var lists: Array[SfzEventList] = [_plan["head"], _plan["tail"]]
	lists.append_array(_plan["bodies"])
	return lists


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
	# Every note already pressed still gets its release, or it would hang: the
	# cursor releases what is sounding when it stops.
	_stop_slots()
	_timelines = {}
	_head = SfzEventList.new()
	_bodies = []
	_tail = SfzEventList.new()


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
	if score == null or not _playing or _pending:
		intensity = level
		_levels = [[-INF, level]]
		return 0.0
	var earliest := maxf(_reached(), _from) + _lead_in + 0.05 + LAYER_EARLY
	var when := earliest if at == "now" else _next_boundary(at, earliest)
	_change_level(when, level)
	# Always sent, even when the level in force does not change: a change
	# still to come that this one supersedes has to go from the cursor too.
	_op(SfzTimeline.OP_SET_LEVEL, level, _frames(when))
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
	_track()
	if _decided:
		return _exit
	if _leaving:
		return _loop_end + (_passes - 1) * _loop_length
	var exit := peek_exit(at, outro, not_before)
	if exit < 0.0 or is_inf(exit):
		return exit
	if not score.has_loop():
		# Without an outro the piece stops there, the notes let go CUT_LIFT
		# before it; with one it is already on its way to its ending.
		if exit < _end:
			_end = exit
		_decided = true
		_exit = exit
		_op(SfzTimeline.OP_LEAVE, 0, _frames(exit))
		return exit
	if exit > _loop_end + (_passes - 1) * _loop_length and at.begins_with("section:"):
		# The section comes round again only in a later pass: the passes up to
		# it are committed now, as the cursor commits them when LEAVE reaches
		# it. peek_exit() has already kept it inside `loop_passes`.
		while _join_frames(_passes) < _frames(exit) - JOIN_SLACK:
			_passes += 1
	var join := _loop_end + (_passes - 1) * _loop_length
	if _frames(exit) < _join_frames(_passes) - JOIN_SLACK:
		# A cut: the cursor lets go CUT_LIFT early, rests the controls and
		# lays the outro from `exit`.
		_closed = true
		_decided = true
		_exit = exit
		_end = exit if not outro else exit + score.duration() - _loop_end
		_op(SfzTimeline.OP_LEAVE, 1 if outro else 0, _frames(exit))
		return exit
	# At the join: sent as the cursor's own frame for it, so a boundary that
	# is the join in seconds is the join to the frame, not a cut beside it.
	_leaving = true
	_bare = not outro
	_op(SfzTimeline.OP_LEAVE, 1 if outro else 0, _join_frames(_passes))
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
	var earliest := maxf(maxf(_reached(), 0.0) + _lead_in + 0.05, not_before)
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
	_track()
	# The tail: the last note still has to ring out, and the longest release
	# on the roster is a couple of seconds. Every cursor has to have ended too:
	# until then something can still sound.
	if _closed and not _pending and conductor.now() > _origin + _end + 2.0:
		for record: Dictionary in _slots:
			if not record["ended"]:
				return
		_playing = false
		set_process(false)
		_slots = []
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
	var plan := {"score": new_score, "head": SfzEventList.new(), "bodies": [] as Array[SfzEventList],
		"tail": SfzEventList.new(), "loop_length": 0.0, "loop_end": 0.0, "lead_in": 0.0,
		"loop_start": 0.0, "end": INF, "marks": {}, "intro_marks": {}, "unmapped": {}, "findings": {}, "said": [],
		"ensemble": "" if against == null else against.id,
		"cast": {} if against == null else against.cast(new_score.parts)}

	if not new_score.has_loop():
		var events := compiler.compile(new_score)
		plan["head"] = SfzEventList.pack(events)
		plan.merge(_report(new_score, events, against), true)
		plan["end"] = new_score.duration()
		plan["marks"] = _marks_of(new_score, 0, new_score.order.size())
		_resolve(plan, against, _plan_rate())
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

	plan["head"] = SfzEventList.pack(head)
	var packed: Array[SfzEventList] = []
	for body in bodies:
		packed.append(SfzEventList.pack(body))
	plan["bodies"] = packed
	plan["tail"] = SfzEventList.pack(tail)
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
	_resolve(plan, against, _plan_rate())
	return plan


# --- Resolving ----------------------------------------------------------------

# The rate a plan is resolved at: the conductor's (an offline render's own
# rate offline), or the audio server's for a plan built with no conductor.
func _plan_rate() -> float:
	return conductor.rate() if conductor != null else AudioServer.get_mix_rate()


# `plan`'s events resolved for `against` at `rate` frames per second, into
# plan["timelines"] (see _timelines) and plan["rate"]. Called by _build(), so
# on prepare()'s worker; reads the plan and the ensemble and nothing of this
# player's. Each layer's timeline is interface A (native/src/timeline.h): the
# head, every body and the tail as rows in the order the conductor used to
# send them - events in time order, each event's rows as SfzTimeline.rows_of()
# makes them - with the loop's frames, the layer's take, and where each
# control the piece moves comes to rest.
static func _resolve(plan: Dictionary, against: SfzEnsemble, rate: float) -> void:
	plan["rate"] = rate
	var timelines := {}
	plan["timelines"] = timelines
	if against == null:
		return
	var for_score: SfzScore = plan["score"]
	var cast: Dictionary = plan["cast"]
	var segments: Array = [plan["head"]]
	segments.append_array(plan["bodies"])
	segments.append(plan["tail"])
	# Ensemble part -> Array per layer of Array per segment of columns.
	var built := {}
	# Ensemble part -> {control: rest value}, for every control it is sent.
	var controls := {}
	for si in segments.size():
		var list: SfzEventList = segments[si]
		for i in list.size():
			var event := list.at(i)
			var part_name: String = cast[event["part"]]["part"] if cast.has(event["part"]) else event["part"]
			if part_name == "" or not against.parts.has(part_name):
				continue
			var part := against.part(part_name)
			if part.layers.is_empty():
				continue
			if not built.has(part_name):
				built[part_name] = _empty_part(part.layers.size(), segments.size())
			if event["kind"] == "cc":
				var used: Dictionary = controls.get_or_add(part_name, {})
				if not used.has(event["control"]):
					used[event["control"]] = _resting_on(part, event["control"])
			var t_f := roundi(float(event["t"]) * rate)
			var lo := 255
			var hi := 255
			if event.has("layer"):
				lo = clampi(int(event["layer"][0]), 0, 254)
				hi = clampi(int(event["layer"][1]), 0, 254)
			var art := 1 if event["kind"] == "art" else 0
			for row: Array in SfzTimeline.rows_of(event, part, rate):
				var columns: Dictionary = built[part_name][row[SfzTimeline.ROW_LAYER]][si]
				columns["t"].append(t_f)
				columns["when"].append(row[SfzTimeline.ROW_WHEN])
				columns["ord"].append(t_f)
				columns["shift"].append(row[SfzTimeline.ROW_SHIFT])
				columns["cls"].append(row[SfzTimeline.ROW_CLS])
				columns["a"].append(row[SfzTimeline.ROW_A])
				columns["b"].append(row[SfzTimeline.ROW_B])
				columns["take"].append(0 if row[SfzTimeline.ROW_TAKE] else SfzTimeline.NO_TAKE)
				columns["lo"].append(lo)
				columns["hi"].append(hi)
				columns["ks"].append(art)

	var has_loop := for_score.has_loop()
	var loop_length := roundi(float(plan["loop_length"]) * rate) if has_loop else 0
	var loop_end := roundi(float(plan["loop_end"]) * rate) if has_loop else 0
	var bodies: int = (plan["bodies"] as Array).size()
	var duration := roundi((for_score.duration() if has_loop else float(plan["end"])) * rate)
	for part_name: String in built:
		var part := against.part(part_name)
		var used: Dictionary = controls.get(part_name, {})
		var per_layer: Array = []
		for li in part.layers.size():
			var layer: SfzEnsemble.Layer = part.layers[li]
			var columns: Array = built[part_name][li]
			var rows := 0
			for c: Dictionary in columns:
				rows += (c["when"] as PackedInt64Array).size()
			if rows == 0:
				per_layer.append({})
				continue
			var rest := PackedInt32Array()
			var rested := {}
			for control: String in used:
				var value: int = used[control]
				if value < 0:
					continue
				var triple := SfzTimeline.rest_of(part, li, control, value)
				if triple.is_empty():
					continue
				var key := "%d|%d" % [triple[0], triple[1]]
				if rested.has(key):
					continue
				rested[key] = true
				rest.append_array(PackedInt32Array(triple))
			var takes: Array = []
			if layer.has_take():
				takes.append({"seed": layer.take_seed(), "timing": layer.take_timing,
					"velocity": layer.take_velocity})
			var body_list: Array = []
			for k in bodies:
				body_list.append(columns[1 + k])
			# The keys it presses and the keyswitches it taps, for the conductor
			# to check against what the layer was loaded with.
			var keys := {}
			var ks_keys := {}
			for c: Dictionary in columns:
				var cls: PackedByteArray = c["cls"]
				var a: PackedByteArray = c["a"]
				for i in cls.size():
					if cls[i] == SfzTimeline.NOTE_ON or cls[i] == SfzTimeline.HIT:
						keys[a[i]] = true
					elif cls[i] == SfzTimeline.ART_ON:
						ks_keys[a[i]] = true
			per_layer.append({
				"head": columns[0], "bodies": body_list, "tail": columns[-1],
				"loop_length": loop_length, "loop_end": loop_end,
				"lead_in": roundi(float(plan["lead_in"]) * rate),
				"tail_base": loop_end + bodies * loop_length,
				"duration": duration, "takes": takes, "has_loop": has_loop,
				"loop_passes": 0, "rest": rest,
				"keys": PackedInt32Array(keys.keys()), "ks_keys": PackedInt32Array(ks_keys.keys()),
			})
		timelines[part_name] = per_layer


# One part's empty columns: per layer, per segment. "ks" marks a keyswitch's
# rows, which the conductor drops on a layer loaded without that key (see
# SfzConductor.claim_timeline()); the native side does not read it.
static func _empty_part(layers: int, segments: int) -> Array:
	var out: Array = []
	for _li in layers:
		var per_segment: Array = []
		for _si in segments:
			per_segment.append({"t": PackedInt64Array(), "when": PackedInt64Array(),
				"ord": PackedInt64Array(), "shift": PackedInt64Array(),
				"cls": PackedByteArray(), "a": PackedByteArray(), "b": PackedByteArray(),
				"take": PackedByteArray(), "lo": PackedByteArray(), "hi": PackedByteArray(),
				"ks": PackedByteArray()})
		out.append(per_segment)
	return out


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
	_rate = _plan_rate()
	if float(plan.get("rate", 0.0)) != _rate:
		# Built against another rate (the output device changed meanwhile):
		# every frame in it is wrong, so it is resolved again.
		_resolve(plan, conductor.ensemble, _rate)
	_timelines = plan["timelines"]
	_leaving = false
	_bare = false
	_decided = false
	_from = 0.0
	_levels = [[-INF, intensity]]
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


# Piece time everything up to which the cursors may already have committed:
# the clock, plus the lead the mix runs ahead by. A decision is only made
# for a moment past this, as one used to be for a moment past what had been
# sent.
func _reached() -> float:
	if not _playing:
		return -INF
	return conductor.now() + conductor.lead() - _origin


# Follows the cursor's commits: whatever follows the last committed pass,
# once its join is close enough that the cursor has decided it - another
# pass, unless the loop has been left or has played its count, and otherwise
# the outro. Run ahead of the cursor rather than behind it (_reached() is
# past the cursor's own horizon), and corrected by what it reports
# (_timeline_report()), so a decision made here never assumes a pass the
# cursor has gone past.
func _track() -> void:
	var horizon := _reached()
	while not _closed and score != null and score.has_loop():
		# The join after pass `_passes`, in seconds from the top.
		var join := _loop_end + (_passes - 1) * _loop_length
		if horizon < join - _lead_in - 0.05:
			return
		var again := not _leaving and (loop_passes <= 0 or _passes < loop_passes)
		if again:
			_passes += 1
		elif _bare:
			# No outro: the pass is the last thing, and it ends at the join.
			_closed = true
			_decided = true
			_exit = join
			_end = join
		else:
			_closed = true
			_decided = true
			_exit = join
			_end = score.duration() + (_passes - 1) * _loop_length


# A frame further than this from a join is not that join (leave_loop()):
# seconds rounded twice can land a frame either side of it.
const JOIN_SLACK := 2


# The frame of the join after pass `passes`, as the cursor counts it.
func _join_frames(passes: int) -> int:
	return _frames(_loop_end) + (passes - 1) * _frames(_loop_length)


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


# Where a control comes to rest on an ensemble part: the part's default, else
# RESTING; -1 for one a cut leaves where it is.
static func _resting_on(part: SfzEnsemble.Part, control: String) -> int:
	if part.defaults.has(control):
		return int(part.defaults[control])
	return int(RESTING.get(control, -1))


# The ensemble part the score part `part_name` is cast on; the name itself
# for a part the cast does not know (a plan built with no ensemble).
func _cast_of(part_name: String) -> String:
	if _cast.has(part_name):
		return _cast[part_name]["part"]
	return part_name


func _frames(seconds: float) -> int:
	return roundi(seconds * _rate)


# --- Intensity -------------------------------------------------------------

func _level_at(t: float) -> int:
	for i in range(_levels.size() - 1, -1, -1):
		if float(_levels[i][0]) <= t:
			return int(_levels[i][1])
	return intensity


# A change to `level` at `when`, as the cursor makes it (SET_LEVEL). Any
# change still to come at or after it is superseded.
func _change_level(when: float, level: int) -> void:
	while _levels.size() > 1 and float(_levels[-1][0]) >= when:
		_levels.pop_back()
	# Changes long past are kept only as far as the one in force.
	while _levels.size() > 1 and float(_levels[1][0]) < _reached() - 10.0:
		_levels.pop_front()
	intensity = level
	if int(_levels[-1][1]) == level:
		return
	_levels.append([when, level])


# What set_intensity() lands on: next_boundary(), or `earliest` itself when
# the piece has no such boundary left.
func _next_boundary(kind: String, earliest: float) -> float:
	var t := next_boundary(kind, earliest)
	return earliest if is_inf(t) else t


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
