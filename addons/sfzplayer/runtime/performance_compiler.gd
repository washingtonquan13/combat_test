class_name SfzPerformanceCompiler
extends SfzScoreCompiler

# The performance compiler: step 5, and the layer the whole project is an
# argument for.
#
# It reads exactly the same Score as the literal compiler and writes to
# exactly the same SfzConductor. Everything it adds is the difference between a
# score being *played back* and a score being *played*:
#
#   dynamics   a written pp..mf is a curve, sampled every beat, and the
#              velocity of each note is read off that curve rather than from
#              a single number per lane
#   metre      downbeats lean, offbeats give way - the thing a sequencer
#              flattens and a musician cannot help doing
#   phrases    the scale between the note and the section: the line is cut
#              into breaths and each one is played as an arc, in dynamics
#              and in time. `shape:` scales it; see the Phrases section
#   timing     no two onsets land on the same grid line. `feel` picks how
#              far off: tight, straight, loose, or swung, and each family sits
#              in its own part of the pocket
#   pocket     `pocket:push` rides ahead of the beat and `pocket:lay` behind
#              it, section by section
#   vibrato    `vib:warm` is a depth envelope over a held note - delayed,
#              opened, closed again - not a constant
#   rotary     `rot:fast` kicks a Leslie into tremolo and `rot:slow` lets it
#              coast back down, over the seconds a rotor actually takes
#   swells     `^` shapes the note's own dynamic, up and back
#   legato     `~` holds a note into the next onset so the library's legato
#              regions have something to fire on
#   articulat. `!` takes marcato, `'` staccato and `+` mute where the ensemble
#              has them, returning to the lane's own articulation after
#
# Two rules keep it honest. It invents nothing the score did not ask for:
# every shape above is driven by a mark or a lane setting. And it never
# writes a control this ensemble has no knob for - not because the Conductor
# would mind (it drops them), but because an unheard CC still costs a slot
# in the scheduler's queue.
#
# Randomness is seeded per player and section, so a piece performs the same way
# every time it is played. Humanization that will not reproduce is a bug
# report you cannot file.

# Every named control this compiler (with SfzScoreCompiler under it) can
# write: the complete set of controls a score is able to reach. Nothing here
# reads it to decide what to emit - the emitters name their controls as
# literals - so it is a statement about them, and scripts/roster_test.gd
# (run by test_roster in tools/run_tests.py) is what holds it to them: it
# runs both compilers against an ensemble that answers every control and fails
# unless what they write and ask about is exactly this set. render.gd's
# --show and --xref name this constant in full; that test also fails if any
# other script holds a copy or an alias of it.
const SCORE_CONTROLS: Array[String] = [
	"dynamics", "vibrato_depth", "rotary", "legato_attack", "sustain",
	"interval_a", "interval_b", "bend",
]

# Seconds between points on a CC curve. Fine enough that a swell sounds
# continuous, coarse enough that a 93-second piece stays inside the queue.
const CC_STEP := 0.05

# Timing, in seconds. The pocket is small on purpose: past about 25ms it
# stops sounding human and starts sounding wrong.
const JITTER := {"tight": 0.004, "straight": 0.009, "loose": 0.021, "swing": 0.012}
const SWING_RATIO := 0.12   # of a beat, added to every offbeat eighth
const ACCENT_RUSH := 0.006  # an accented note arrives fractionally early

# Jitter alone is what a machine thinks a human sounds like: every note
# independently a few milliseconds off, which averages out to dead on the
# grid and sounds like it. A player's error is mostly correlated - they sit
# a little ahead for a bar, settle, drift a little behind - so most of the
# looseness is a slow wander, and the jitter above is only the small part
# on top. DRIFT is how far the wander may go; each note moves it by up to
# DRIFT_MOVE of that, and DRIFT_KEEP of where it was carries over.
const DRIFT := {"tight": 0.007, "straight": 0.010, "loose": 0.016, "swing": 0.010}
const DRIFT_MOVE := 0.35
const DRIFT_KEEP := 0.8

# The second and fourth sixteenth of a beat land a touch late: an upstroke
# after a downstroke, the hand on its way back. This is the difference
# between sixteenths that drive and sixteenths that tick. Swing has its own.
const SIXTEENTH_LAG := {"tight": 0.005, "straight": 0.007, "loose": 0.010, "swing": 0.0}

# Nobody releases every note at exactly the same length. Up to this fraction
# either way, on notes that are not slurred or held to the next onset.
const RELEASE_VARY := 0.08

# Where each base family sits against the beat. Drums lead, bass lays back a hair,
# pads start early because a slow attack means the note speaks late.
const POCKET := {
	"lead": 0.007, "guitar": 0.006, "keys": 0.003, "bass": 0.005,
	"pad": -0.030, "perc": -0.004,
}

# A lane's pocket (push or lay back) is felt most between the beats: the
# beat is where everyone meets, and the notes in between are where a player
# leans. So the beat itself moves only part of the way. Played alone a
# constant shift would be no shift at all; it is the gap between beat and
# offbeat that makes a line sound urgent or heavy. Length leans the same
# way - a pushed note lets go early, a laid-back one hangs on.
const POCKET_ON_BEAT := 0.4   # of the lane's pocket, applied on the beat
const POCKET_LENGTH := 5.0    # length change per second of pocket

# Metre, in velocity. A bar has a shape even when every note is written the
# same, and this is most of what makes a flat sequence sound like typing.
const DOWNBEAT := 7
const HALFBAR := 3
const OFFBEAT := -5

const VELOCITY_JITTER := 4

# A pick crosses the strings one after another, so a chord on a guitar is a
# very fast arpeggio: low string first on a downstroke, the next a couple of
# milliseconds behind. Every string of a chord landing on the same sample is
# a keyboard's chord, and on a distorted guitar it is the attack that gives
# a sequenced riff away. Seconds per string, for the base families that pick; an
# accented chord is struck harder and the pick moves faster, so it spreads
# less.
const STRUM := {"guitar": 0.0022}
const STRUM_ACCENT := 0.7

# Legato. A slurred note is held past the next onset by this much, and the
# note it slurs into is played a little softer - a tongued note is louder
# than a slurred one on every instrument that can tell the difference.
const SLUR_OVERLAP := 0.035
const SLUR_SOFTEN := 7

# A key cannot be pressed while it is already down. Where a note repeats the
# pitch before it, the earlier one has to be lifted first, by enough that the
# synth sees two presses rather than one press and a stray release - which is
# what a player's hand does anyway. Only that pitch is shortened; the rest of
# a chord holds.
const REPEAT_LIFT := 0.045
const REPEAT_KEEP := 0.35   # never cut a repeated note below this of its gap
# A new pitch on an instrument whose release cuts off the next note (see
# _hold) needs only its release to land before that note's press.
const CUT_LIFT := 0.008

# How far CC73 is pushed under a slur, where the ensemble maps legato_attack.
const LEGATO_ATTACK := 96

# The shape of getting to the depth a lane asked for; the depths themselves
# are SfzScore.VIBRATO, because they are score vocabulary rather than phrasing.
const VIBRATO_DELAY := 0.30   # of the note, before the depth starts opening
const VIBRATO_OPEN := 0.75    # of the note, by which it is fully open
const VIBRATO_MIN := 0.50     # seconds; shorter notes are left alone

# Rotary speed, where the ensemble maps `rotary`. A Leslie has two speeds and a
# switch, not a knob, so these are the two ends of the control rather than
# points on a scale. The seconds are the interesting part: the cabinet is a
# horn and a drum on belts, and the whole sound of throwing that switch is
# the several seconds the rotors take to get there. Up is quicker than down
# because a motor accelerates a rotor and nothing decelerates it but air.
const ROTARY := {"slow": 0, "fast": 127}
const ROTARY_UP := 1.2        # seconds, chorale -> tremolo
const ROTARY_DOWN := 3.0      # seconds, tremolo -> chorale
const ROTARY_EASE := 2.2      # >1 leaves the old speed fast, settles slowly

# A swell dips below its written level before it climbs above it, because a
# crescendo that starts at full is not a crescendo.
const SWELL_FROM := 0.55
const SWELL_TO := 1.25
const SWELL_PEAK := 0.80      # of the note

var _rng := RandomNumberGenerator.new()
var _drift := 0.0

# Where each onset of a player's split lanes has already landed, so the next
# lane of that player - a sub-lane or a co-part - to play at that moment
# lands with it: "perc@12.5" -> seconds off the grid.
# Two limbs of one drummer are not two players - a kick under a hat is one
# motion, and the drift and the pocket belong to the person, not the foot.
# Each limb still adds its own hair of error on top, which is the flam a real
# kit has and a drum machine does not.
var _together: Dictionary = {}
const LIMB_JITTER := 0.0025
var _beats_per_bar := 4

# Which way each player's cabinet is spinning as the timeline reaches this
# section, keyed by player so a co-part reaching for the switch throws the
# same one. A rotor does not reset between sections, so neither does this.
var _rotary_at: Dictionary = {}


func describe() -> String:
	return "performance"


func compile(score: SfzScore) -> Array:
	var out: Array = []
	_beats_per_bar = score.beats_per_bar
	_rotary_at.clear()
	_bend_warned.clear()
	_title = score.title
	fell_back = {}
	# Every question below is asked of the ensemble part a score part is cast
	# on. Without this the literal compiler's cast is never made here, and a
	# part the ensemble lacks by name reads as the empty part: on its own
	# ensemble nothing changes, since every part is there, but played
	# anywhere else a recast line loses the curves its new part can hear -
	# or keeps the last score's cast, which is worse.
	cast_for(score)

	var timeline := score.timeline()
	for at in timeline.size():
		var entry: Dictionary = timeline[at]
		var section_first := out.size()
		var section: SfzScore.Section = score.sections[entry["name"]]
		var origin: float = entry["at"]
		var spb: float = 60.0 / float(entry["bpm"])
		var beats: float = section.beats(_beats_per_bar)

		_together.clear()
		for name in section.lanes:
			var lane: SfzScore.Lane = section.lanes[name]
			# Seeded from what the lane *is*, not from when it plays, so a
			# piece performs the same way on every run, live or offline, and
			# a section that appears twice in the written order performs the
			# same both times.
			#
			# The pass is the exception, and it is not "when it plays"
			# either - it is the player saying this copy of the loop is a
			# different time round. Without it the second pass is the first
			# pass to the sample: same jitter, same drift, same velocities,
			# a tape splice rather than a band playing the figure again.
			# Pass n is still identical on every run, so nothing about
			# reproducibility changes.
			# The first pass keeps the seed it has always had, down to the
			# byte: every render approved before this existed is still that
			# render, and only the copies after the first are new.
			var round := pass_at(at)
			#
			# `name` is the lane's performance name and the last field its
			# player, so a co-part split out of a voice (`high` played by
			# lead) seeds as the voice's lane did: section/lead.high/lead.
			_rng.seed = hash("%s/%s/%s" % [section.name, name, lane.player]
					if round == 0
					else "%s/%s/%s/%d" % [section.name, name, lane.player, round])
			_drift = 0.0
			var first := out.size()
			_lane(out, lane, lane.part, origin, spb, beats)
			tag_lane(out, first, lane)
		tag_section(out, section_first, at)

	return _switched(sorted(out))


# Keeps only the keyswitches that change something. A lane asks for every
# note's articulation, because a keyswitch is sent to the part's channel and
# the part may have other lanes: a fill written `guitar.fx art:pinch` leaves
# the channel on pinch, and a lane that tracked only its own last switch sent
# nothing for its next plain note, which then squealed too. Which switch is
# redundant can only be told here, with every lane of the part in time order.
#
# Kept per section, so each section's first notes still send their switches
# and a player seeking or looping to it hears it as written. A lane given a layer
# switches that layer alone; a switch to the whole part changes every layer.
#
# Two lanes of one part cannot both be heard as written when one switches
# the channel after the other has switched it and before that lane's note has
# sounded: the note plays on the later key. That is reported, for the score to
# move one of them. Lanes that make the same switch (a line doubled an octave
# down) are not in each other's way.
func _switched(events: Array) -> Array:
	var on := {}
	var by := {}
	var kept: Array = []
	for ev: Dictionary in events:
		if ev["kind"] == "note":
			var sounding := "%s|%s|" % [ev.get("section", -1), ev["part"]]
			for k: String in by.keys():
				if k.begins_with(sounding) and ev.get("perf", "") in by[k]["perfs"]:
					by[k]["waiting"].erase(ev.get("perf", ""))
		if ev["kind"] != "art":
			kept.append(ev)
			continue
		var part := "%s|%s" % [ev.get("section", -1), ev["part"]]
		var layer: String = str(ev.get("layer", []))
		var key := part + "|" + layer
		var last: Dictionary = by.get(key, {})
		if on.get(key, "") == ev["art"]:
			if last.get("art", "") == ev["art"]:
				last["perfs"].append(ev.get("perf", ""))
				last["waiting"].append(ev.get("perf", ""))
			continue
		var waiting: Array = last.get("waiting", [])
		if not waiting.is_empty() and not ev.get("perf", "") in waiting:
			note_fallback(ev["part"], "clash:" + ev["art"],
					"before %s's '%s' note has sounded; one key plays both notes"
					% [waiting[0], last["art"]], ev.get("perf", ""))
		by[key] = {"perfs": [ev.get("perf", "")], "waiting": [ev.get("perf", "")], "art": ev["art"]}
		if ev.get("layer", []).is_empty():
			for k: String in on.keys():
				if k.begins_with(part + "|"):
					on.erase(k)
		else:
			on.erase(part + "|" + str([]))
		on[key] = ev["art"]
		kept.append(ev)
	return kept


# --- One lane ------------------------------------------------------------

func _lane(out: Array, lane: SfzScore.Lane, part: String, origin: float,
		spb: float, beats: float) -> void:
	var from := _level(lane.dyn_from, 78)
	var to := _level(lane.dyn_to, from)

	_shaping = SfzScore.SHAPE.get(lane.shape, 1.0)
	_lane_end = beats
	_spans = _phrases(lane, beats) if _shaping > 0.0 else []

	# Every note sends its own switch, so the lane's articulation needs no
	# switch of its own at the top of the section - and one there was wrong:
	# a note the pocket plays early switches ahead of the downbeat, and the
	# lane's switch then landed after it; another lane of the part had its
	# opening switch land between this lane's switch and its note. An
	# articulation the part cannot switch to is still sent, so prepare()
	# reports the lane that asked for it.
	if lane.art != "" and not has_keyswitch(part, lane.art):
		emit_art(out, part, origin - SETUP_LEAD, lane.art)

	if lane.rot != "":
		if not has_control(part, "rotary"):
			note_fallback(part, "control:rotary", "the cabinet stays at the speed it has")
		_rotary(out, part, lane.player, origin, lane.rot)

	# A flat level needs no control: velocity carries it whole. A ramp does,
	# on anything that holds a note, and a kit holds none.
	if to != from and not has_control(part, "dynamics") and not _all_drums(lane):
		note_fallback(part, "control:dynamics", FLAT_DYNAMICS)
	_dynamic_curve(out, part, origin, spb, beats, from, to)

	var previous_slurred := false
	var previous: SfzScore.Event = null

	for i in lane.events.size():
		var e: SfzScore.Event = lane.events[i]
		var base := int(round(lerpf(float(from), float(to), _across(e.at, beats))))
		var slid_into := previous != null and previous.slide and not e.keys.is_empty() \
				and not previous.keys.is_empty()
		var velocity := _velocity(e, base, previous_slurred or slid_into)
		var t: float = origin + e.at * spb + _timing(part, lane, e, spb)

		if not e.drum.is_empty():
			emit_hit(out, part, t, e.drum, velocity)
			previous_slurred = false
			previous = e
			continue

		# A muted note where the part has no mute samples but can play each
		# string dead: the thud of the string it sits on, not the pitched note
		# cut short that the staccato fallback would give (dead_string()).
		if e.muted and not e.keys.is_empty() and not has_keyswitch(part, "mute"):
			var dead := {}
			for key in e.keys:
				var drum := dead_string(part, key)
				if drum != "":
					dead[drum] = true
			if not dead.is_empty():
				for drum: String in dead:
					emit_hit(out, part, t, drum, velocity)
				previous_slurred = false
				previous = e
				continue

		var duration := _duration(lane, part, i, e, spb)

		# An articulation the note itself asks for, where the ensemble has one.
		var want := _articulation(part, lane, e, previous_slurred)
		var slide := _slide(out, part, t, e, previous if slid_into else null)
		if slide != "":
			want = slide
		elif can_bend(part):
			_bend(out, part, lane, i, t, spb, duration, previous if slid_into else null)
		# Asked of the lane's part, as the conductor plays it: a part of
		# layers with no keys is sent no keyswitch, not an idle tap it skips.
		# Sent for every note, and the ones that change nothing dropped once
		# every lane is in (_switched()): another lane of the part may have
		# switched the channel since this lane's last note.
		if has_keyswitch(part, want):
			emit_art(out, part, t - 0.03, want)

		if e.swell:
			if not has_control(part, "dynamics"):
				note_fallback(part, "control:dynamics", FLAT_DYNAMICS)
			_swell(out, part, t, duration, base)

		_legato(out, part, t, e.slur, previous_slurred)

		if lane.vib != "" and duration >= VIBRATO_MIN:
			if not has_control(part, "vibrato_depth"):
				note_fallback(part, "control:vibrato_depth", "those notes are held without it")
			_vibrato(out, part, t, duration, lane.vib)

		var strings := e.keys.duplicate()
		strings.sort()
		var stroke: float = STRUM.get(lane.base, 0.0) * (STRUM_ACCENT if e.accent else 1.0)
		# Where a release cuts off what still sounds, a chord's strings let go
		# together: the first one lifted would silence the rest.
		var together := -1.0
		if release_cuts(part):
			for key in strings:
				var h := _hold(lane, part, i, spb, key, duration)
				together = h if together < 0.0 else minf(together, h)
		for n in strings.size():
			var key: int = strings[n]
			var hold := together if together >= 0.0 else _hold(lane, part, i, spb, key, duration)
			emit_note(out, part, t + n * stroke, key, velocity, hold - n * stroke)

		if e.fall and not e.keys.is_empty() and has_keyswitch(part, "slide_out"):
			_fall(out, part, lane, i, t, spb, velocity, duration)
		elif e.fall and not e.keys.is_empty():
			note_fallback(part, "art:slide", BENT)

		previous_slurred = e.slur
		previous = e

	# A lane that ends mid-slur still has to put the pedal down.
	if previous_slurred:
		_legato(out, part, origin + beats * spb, false, true)


# --- Legato --------------------------------------------------------------

# A slur is one bow, one breath, one pedal. The attack softens, and on an
# instrument with a damper the pedal goes down and stays down until the run
# ends - which is why this fires on the notes that break a slur as much as
# on the ones that start one. The old version only ever pushed CC73 up, so
# one slurred note left the whole rest of the lane playing legato.
func _legato(out: Array, part: String, t: float, slurred: bool,
		was_slurred: bool) -> void:
	if slurred == was_slurred:
		return
	if has_control(part, "legato_attack"):
		emit_cc(out, part, t - 0.02, "legato_attack", LEGATO_ATTACK if slurred else 0)
	if has_control(part, "sustain"):
		# Lifted a hair earlier than it is pressed, so the release is heard as
		# a release rather than as the next note failing to speak.
		emit_cc(out, part, t - (0.02 if slurred else 0.04), "sustain", 127 if slurred else 0)


# --- Dynamics ------------------------------------------------------------

# The written ramp and the phrase arcs on top of it, as one control curve
# under the whole lane. This is the slow shape a player holds in mind, not
# the per-note detail, which rides on velocity - but it has to carry the
# same phrasing, because on a sustaining instrument the curve *is* the
# dynamic and a velocity that nothing reads shapes nothing. Half a beat,
# because a four-beat phrase has to arch in four points, not two.
func _dynamic_curve(out: Array, part: String, origin: float, spb: float,
		beats: float, from: int, to: int) -> void:
	if not has_control(part, "dynamics"):
		return
	if from == to and _shaping <= 0.0:
		emit_cc(out, part, origin - SETUP_LEAD, "dynamics", cc_from_velocity(from))
		return
	var last := -1
	var b := 0.0
	while b <= beats:
		var written := lerpf(float(from), float(to), _across(b, beats))
		var level := int(round(written + _phrase_level(b)))
		var value := cc_from_velocity(clampi(level, 1, 127))
		if value != last:
			emit_cc(out, part, origin + b * spb - SETUP_LEAD, "dynamics", value)
			last = value
		b += 0.5


# A note's own crescendo: under its written level, up past it, and back by
# the time it releases.
func _swell(out: Array, part: String, t: float, duration: float, base: int) -> void:
	if not has_control(part, "dynamics"):
		return
	var peak := duration * SWELL_PEAK
	var last := -1
	var x := 0.0
	while x <= duration:
		var f := (x / peak) if x < peak else (1.0 - (x - peak) / maxf(duration - peak, 0.001))
		var level := base * lerpf(SWELL_FROM, SWELL_TO, clampf(f, 0.0, 1.0))
		var value := cc_from_velocity(int(round(level)))
		if value != last:
			emit_cc(out, part, t + x - 0.02, "dynamics", value)
			last = value
		x += CC_STEP


# --- Vibrato -------------------------------------------------------------

# Depth over one held note: flat while the note speaks, opening through the
# middle, closing before the release. Returns to the ensemble's resting value so
# the next note starts clean.
func _vibrato(out: Array, part: String, t: float, duration: float, vib: String) -> void:
	if not has_control(part, "vibrato_depth"):
		return
	var rest := default_for(part, "vibrato_depth", 20)
	var peak := int(round(127.0 * float(SfzScore.VIBRATO.get(vib, 0.5))))
	if peak <= rest:
		return

	var delay := duration * VIBRATO_DELAY
	var open := duration * VIBRATO_OPEN
	var last := -1
	var x := delay
	while x <= duration:
		var f: float = (x - delay) / maxf(open - delay, 0.001) if x < open \
			else 1.0 - (x - open) / maxf(duration - open, 0.001)
		var value := int(round(lerpf(float(rest), float(peak), clampf(f, 0.0, 1.0))))
		if value != last:
			emit_cc(out, part, t + x, "vibrato_depth", value)
			last = value
		x += CC_STEP
	emit_cc(out, part, t + duration, "vibrato_depth", rest)


# --- Rotary --------------------------------------------------------------

# Throwing the speed switch on a rotary cabinet.
#
# This is not a fade between two settings, it is a ramp that takes time on
# purpose. On the instrument the switch is instant and the sound is not: the
# horn and the drum are spun by belts, so the pitch wobble and the tremolo
# slide up to the new rate over a second or three, and that slide is the
# gesture. A player reaches for it at the moment the music opens up, which is
# why the ramp starts on the downbeat of the section that asked for it rather
# than arriving already at speed.
#
# It only writes when the speed actually changes, and it remembers across
# sections, so a run of `rot:fast` lanes spins up once and stays up.
func _rotary(out: Array, part: String, player: String, origin: float, rot: String) -> void:
	if not has_control(part, "rotary"):
		return
	var target: int = ROTARY.get(rot, -1)
	if target < 0:
		return
	var from: int = _rotary_at.get(player, default_for(part, "rotary", 0))
	if from == target:
		return
	_rotary_at[player] = target

	var span := ROTARY_UP if target > from else ROTARY_DOWN
	var last := -1
	var x := 0.0
	while x < span:
		var f := 1.0 - pow(1.0 - x / span, ROTARY_EASE)
		var value := int(round(lerpf(float(from), float(target), f)))
		if value != last:
			emit_cc(out, part, origin + x, "rotary", value)
			last = value
		x += CC_STEP
	emit_cc(out, part, origin + span, "rotary", target)


# --- Phrases -------------------------------------------------------------
#
# The scale between the note and the section: what a player breathes in.
#
# Everything else in this file works at one of two scales. The note - velocity
# jitter, the metre accent, the swing - or the whole lane: one `dyn:` ramp,
# one pocket, one feel, held flat from the first bar to the last. A real
# performance has a third scale in between, and its absence is most of what
# makes a written-out crescendo sound written out. Sixteen bars that rise by
# exactly the same amount on every beat is a fader move. A player instead
# shapes each phrase - leans into it, peaks past the middle, and relaxes into
# the cadence - and the sixteen-bar rise is what those phrases are stacked on.
#
# Where the phrases are is not written in the score, because a player reading
# the same page is not told either. A phrase ends where the line stops: at a
# rest, after a note markedly longer than its neighbours, at a hole in the
# writing - and failing all three at a four-bar boundary, which is what an
# ostinato gets. It never rests and it still has to breathe.

const PHRASE_BARS := 4.0      # the fallback breath, for a line that never stops
const PHRASE_MIN := 2.0       # beats; shorter than this is a gasp, not a phrase
const PHRASE_LONG := 1.8      # a note this many times the lane's median ends one
# How long the line has to stop before the stop reads as a breath. Without
# this, a hi-hat playing sixteenths with sixteenth rests between them comes
# out as sixteen two-beat "phrases" and pumps twice a bar; nobody hears a
# rest that short as the end of anything. It is the same number for a held
# note: a phrase can only end on a note long enough to end on.
const PHRASE_GAP := 1.0       # beats

const PHRASE_PEAK := 0.62     # where in the phrase the line leans hardest
const PHRASE_LIFT := 6.0      # velocity, at that peak
const PHRASE_SETTLE := -4.0   # velocity, entering the phrase
const CADENCE_DROP := -7.0    # velocity, released into the close
const CADENCE_REACH := 0.18   # of the phrase, over which the close arrives

const PHRASE_PRESS := -0.007  # seconds; the body of a phrase leans forward
const CADENCE_BROADEN := 0.020  # seconds; and the close arrives late

var _spans: Array = []        # [from, to] in beats, for the lane being compiled
var _shaping := 1.0
var _lane_end := 0.0           # beats, for the lane being compiled


# The phrases of one lane, as beat spans covering the whole section.
func _phrases(lane: SfzScore.Lane, beats: float) -> Array:
	var median := _median_duration(lane)
	var bounds: Array[float] = [0.0, beats]
	# A kit is read for its bar groups and nothing finer. The rule below
	# looks for the places a line stops, and a groove stops constantly
	# without ever ending a phrase - a hat pattern came out as fifteen
	# two-beat spans, and differently in every section, which is the
	# inference finding noise. A drummer has no breath to take: their
	# phrasing is the four-bar shape, which is what the fallback gives.
	var reads := not _all_drums(lane)
	for i in (lane.events.size() if reads else 0):
		var e: SfzScore.Event = lane.events[i]
		if e.is_rest():
			# The breath itself: the phrase ended when the sound did.
			if e.duration >= PHRASE_GAP:
				bounds.append(e.at)
				bounds.append(e.at + e.duration)
			continue
		# A slur or a slide is one breath by definition and cannot be cut.
		if e.slur or e.slide or e.at < 0.001:
			continue
		var long_note := (median > 0.0 and e.duration >= median * PHRASE_LONG
				and e.duration >= PHRASE_GAP)
		var gap := false
		if i + 1 < lane.events.size():
			var next: SfzScore.Event = lane.events[i + 1]
			gap = next.at - (e.at + e.duration) >= PHRASE_GAP
		if long_note or gap:
			bounds.append(e.at + e.duration)

	bounds.sort()
	var grid := PHRASE_BARS * float(_beats_per_bar)
	var filled: Array[float] = []
	for i in bounds.size():
		var b: float = clampf(bounds[i], 0.0, beats)
		if not filled.is_empty() and b - filled[-1] < 0.001:
			continue
		# A stretch far longer than a breath is cut into bar groups.
		if not filled.is_empty():
			var walk: float = filled[-1]
			while b - walk > grid * 1.5:
				walk += grid
				filled.append(walk)
		filled.append(b)
	if filled.size() < 2:
		return [[0.0, maxf(beats, PHRASE_MIN)]]

	# Anything too short to be a phrase belongs to the one before it.
	var out: Array = []
	var start: float = filled[0]
	for i in range(1, filled.size()):
		if filled[i] - start >= PHRASE_MIN:
			out.append([start, filled[i]])
			start = filled[i]
	if out.is_empty():
		return [[filled[0], filled[-1]]]
	if start < filled[-1] - 0.001:
		out[-1][1] = filled[-1]
	return out


func _all_drums(lane: SfzScore.Lane) -> bool:
	var sounded := false
	for e in lane.events:
		if e.is_rest():
			continue
		if e.drum.is_empty():
			return false
		sounded = true
	return sounded


func _median_duration(lane: SfzScore.Lane) -> float:
	var lengths: Array[float] = []
	for e in lane.events:
		if not e.is_rest():
			lengths.append(e.duration)
	if lengths.is_empty():
		return 0.0
	lengths.sort()
	return lengths[lengths.size() / 2]


# How far through its phrase this beat is, 0 to 1; -1 where nothing applies.
func _phrase_pos(at: float) -> float:
	for span in _spans:
		var width: float = span[1] - span[0]
		if width <= 0.001:
			continue
		if at < span[1] - 0.001:
			return clampf((at - span[0]) / width, 0.0, 1.0)
	# Past the last phrase - a lane that runs over its section's bar count.
	return 1.0 if not _spans.is_empty() else -1.0


# The arc, in velocity: under the written level entering the phrase, over it
# past the middle, and released into the close.
func _phrase_level(at: float) -> float:
	if _shaping <= 0.0:
		return 0.0
	var pos := _phrase_pos(at)
	if pos < 0.0:
		return 0.0
	var v: float
	if pos < PHRASE_PEAK:
		v = lerpf(PHRASE_SETTLE, PHRASE_LIFT, smoothstep(0.0, 1.0, pos / PHRASE_PEAK))
	else:
		v = lerpf(PHRASE_LIFT, PHRASE_SETTLE,
				smoothstep(0.0, 1.0, (pos - PHRASE_PEAK) / (1.0 - PHRASE_PEAK)))
	v += CADENCE_DROP * _closing(pos)
	return v * _shaping


# The same arc in time: the body of a phrase presses forward a few
# milliseconds and the close broadens, which is the agogic half of phrasing
# and the half no amount of velocity can imitate.
func _phrase_time(at: float) -> float:
	if _shaping <= 0.0:
		return 0.0
	var pos := _phrase_pos(at)
	if pos < 0.0:
		return 0.0
	var body := clampf(pos / (1.0 - CADENCE_REACH), 0.0, 1.0)
	return (PHRASE_PRESS * sin(PI * body) + CADENCE_BROADEN * _closing(pos)) * _shaping


# 0 through the body of a phrase, easing to 1 at its very end.
func _closing(pos: float) -> float:
	if pos <= 1.0 - CADENCE_REACH:
		return 0.0
	return smoothstep(0.0, 1.0, (pos - (1.0 - CADENCE_REACH)) / CADENCE_REACH)


# --- Velocity and time ---------------------------------------------------

func _velocity(e: SfzScore.Event, base: int, after_slur: bool) -> int:
	var v := float(e.velocity(base))
	v += _metre(e.at)
	v += _phrase_level(e.at)
	if after_slur:
		v -= SLUR_SOFTEN
	v += _rng.randf_range(-VELOCITY_JITTER, VELOCITY_JITTER)
	return clampi(int(round(v)), 1, 127)


# Where in the bar this beat falls, in velocity.
func _metre(at: float) -> float:
	var into := fposmod(at, float(_beats_per_bar))
	if absf(into) < 0.001:
		return DOWNBEAT
	if absf(into - floorf(into)) > 0.001:
		return OFFBEAT
	if absf(into - float(_beats_per_bar) / 2.0) < 0.001:
		return HALFBAR
	return 0.0


# How far off the grid this onset lands, in seconds.
func _timing(part: String, lane: SfzScore.Lane, e: SfzScore.Event, spb: float) -> float:
	var accent := -ACCENT_RUSH if e.accent else 0.0
	var key := "%s@%.4f" % [lane.player, e.at]
	if lane.name != lane.player and _together.has(key):
		return _together[key] + _rng.randf_range(-LIMB_JITTER, LIMB_JITTER) + accent
	var offset := _grid_offset(part, lane, e, spb)
	if lane.name != lane.player:
		_together[key] = offset
	return offset + accent


# The part of the timing that belongs to the player rather than the note.
func _grid_offset(part: String, lane: SfzScore.Lane, e: SfzScore.Event, spb: float) -> float:
	var offset: float = POCKET.get(lane.base, 0.0)
	# A kit keeps the grid: it phrases with its dynamics, never with its
	# time, because the rest of the band is reading the time off it.
	if e.drum.is_empty():
		offset += _phrase_time(e.at)
	var spread: float = JITTER.get(lane.feel, JITTER["straight"])
	offset += _rng.randf_range(-spread, spread)

	var reach: float = DRIFT.get(lane.feel, DRIFT["straight"])
	_drift = clampf(_drift * DRIFT_KEEP + _rng.randf_range(-1.0, 1.0) * reach * DRIFT_MOVE,
			-reach, reach)
	offset += _drift

	var into_beat := fposmod(e.at, 1.0)
	var on_beat := into_beat < 0.001 or into_beat > 0.999
	offset += lane.pocket * (POCKET_ON_BEAT if on_beat else 1.0)

	if absf(into_beat - 0.25) < 0.001 or absf(into_beat - 0.75) < 0.001:
		offset += SIXTEENTH_LAG.get(lane.feel, 0.0)

	if lane.feel == "swing" and absf(fposmod(e.at, 1.0) - 0.5) < 0.001:
		offset += spb * SWING_RATIO
	return offset


# A slurred note is held into the next onset rather than released before it,
# which is the only way a legato mapping ever fires. Where the legato is a
# keyswitch instead, the overlap is not needed and does harm: it is lifted
# just short, the same as a slide (see SLIDE_LIFT).
func _duration(lane: SfzScore.Lane, part: String, i: int, e: SfzScore.Event,
		spb: float) -> float:
	if (e.slur or e.slide) and i + 1 < lane.events.size():
		var next: SfzScore.Event = lane.events[i + 1]
		if next.at > e.at:
			# A bent slide is one mono voice handing over to the next note, so
			# it overlaps like a slur: the new note takes the voice, and the
			# old one never gets a release of its own to sound bent in.
			if e.slide and can_bend(part):
				return (next.at - e.at) * spb + SLUR_OVERLAP
			if e.slide or has_keyswitch(part, "legato"):
				return (next.at - e.at) * spb - SLIDE_LIFT
			return (next.at - e.at) * spb + SLUR_OVERLAP
	var length := e.sounding_duration() * spb
	length *= 1.0 + lane.pocket * POCKET_LENGTH
	if not e.tenuto:
		length *= 1.0 + _rng.randf_range(-RELEASE_VARY, RELEASE_VARY)
	return length


# The same duration, cut short if the next event presses this very key again.
# Tenuto ends exactly on the next onset and a slur deliberately runs past it,
# both of which are right for a new pitch and wrong for a repeated one: the
# release lands on top of the new press and silences it. What is heard then is
# not a short note, it is a hole in the line where a note was written.
#
# The gap is read off the written beats rather than off the two onsets,
# because the second one has not been given its timing jitter yet and asking
# the generator for it here would spend the number the note itself is about to
# need. The worst the jitter can do to the gap is to push this note as late as
# it goes and pull the next as early, so that is what comes off it, along with
# the swing push if this note is the offbeat eighth that gets one. Only the
# repeated key is shortened; the rest of a chord holds as written.
#
# On an instrument whose release samples cut off what is still sounding
# (release_cuts: Standard Bass, metal-gtx), every key is a repeated key: any
# note that is still down when the next one arrives lets go on top of it, and
# its release silences the note just played. There every note ends short of
# the next onset by the same worst case, lifted CUT_LIFT rather than
# REPEAT_LIFT - the key is not being pressed twice, so the release sample
# only has to land first. Its own tail carries the note to the next one.
func _hold(lane: SfzScore.Lane, part: String, i: int, spb: float, key: int,
		duration: float) -> float:
	var cuts := release_cuts(part)
	var here: SfzScore.Event = lane.events[i]
	var next_at := _lane_end
	var next_keys := 1
	var repeated := false
	if i + 1 < lane.events.size():
		var next: SfzScore.Event = lane.events[i + 1]
		repeated = next.keys.has(key)
		if not repeated and (next.keys.is_empty() or not cuts):
			return duration
		next_at = next.at
		next_keys = next.keys.size()
	elif not cuts:
		return duration
	# The last note of a lane on such an instrument cannot see the next
	# section's first one, so it ends short of the section's end as if one
	# were there: at worst it gives up a few milliseconds before a rest.

	var gap: float = (next_at - here.at) * spb
	if gap <= 0.0:
		return duration
	# Room for the next note to arrive as early as the timing can make it.
	gap -= 2.0 * float(JITTER.get(lane.feel, JITTER["straight"]))
	gap -= 2.0 * float(DRIFT.get(lane.feel, DRIFT["straight"])) * DRIFT_MOVE
	gap -= float(SIXTEENTH_LAG.get(lane.feel, 0.0))
	gap -= ACCENT_RUSH
	gap -= absf(lane.pocket) * (1.0 - POCKET_ON_BEAT)
	# A key that is a higher string of one chord and a lower one of the next
	# is picked later the first time than the second.
	gap -= float(STRUM.get(lane.base, 0.0)) * float(maxi(here.keys.size(), next_keys) - 1)
	if lane.feel == "swing":
		gap -= spb * SWING_RATIO
	var lift := REPEAT_LIFT if repeated else CUT_LIFT
	return minf(duration, maxf(gap - lift, gap * REPEAT_KEEP))


# The note a slur lands on is the one that is not picked: a hammer-on or a
# pull-off on a bass or guitar, a legato transition on anything that records
# them. Where the ensemble has no such samples the slur is still heard, through
# the overlap and the softer attack in _legato().
#
# A plain note is a return to the lane's own articulation, or the ensemble's
# resting one if the lane names none. This has to be an articulation in its
# own right: when it was "", which no ensemble has a keyswitch for, one muted
# note left every note after it muted until something else changed it.
#
# A mark the ensemble has no samples for falls back the same way: on a bass,
# `'` is an open note cut short by the hand, not a keyswitch, so it must not
# inherit whatever the note before it switched to.
#
# "Has samples" means the lane's part has them. Asking a wider group sent
# long-time-way's lead.cry, a synth with no keys, a resting "sustain" tap
# nobody could press; a part is exactly the layers its lanes sound on.
func _articulation(part: String, lane: SfzScore.Lane, e: SfzScore.Event,
		after_slur: bool) -> String:
	var resting := lane.art if lane.art != "" else resting_art(part)
	var want := resting
	if e.muted:
		want = "mute" if has_keyswitch(part, "mute") else "staccato"
		if want != "mute" and not e.keys.is_empty():
			note_fallback(part, "art:mute", "played on the staccato key"
					if has_keyswitch(part, want) else "played short, in the articulation it has")
	elif e.staccato:
		want = "staccato"
	elif after_slur and has_keyswitch(part, "legato"):
		want = "legato"
	elif e.accent:
		want = "marcato"
	return want if has_keyswitch(part, want) else resting


# --- Slides --------------------------------------------------------------

# A slide on a bass is one pluck and a finger that travels. The library plays
# it as the target note, unpicked, bent in from the fret the finger left, one
# semitone at a time the way frets go by; CC26 says how many frets that is
# (1 to 6, or its seven-fret "omni" beyond that) and CC111 how quickly they
# go by. So the direction and the distance are read off the two notes as
# written, and the score only ever says "slide", never how.
#
# Scoops come in from nowhere in particular, a few frets under the note, and
# are counted on CC27 instead.
const SCOOP_FRETS := 3

# A slide's first note lets go a hair before the second arrives, never after.
# Lifting a key fires the library's release sample, and that sample chokes
# every sounding note - so a first note held past the second, the way a slur
# is, kills the note it slid into the moment it lets go. Lifted first, the
# release is choked by the arriving note instead, and the first note's own
# fade covers the join.
const SLIDE_LIFT := 0.005

func _slide(out: Array, part: String, t: float, e: SfzScore.Event,
		from: SfzScore.Event) -> String:
	if from != null:
		var step: int = e.keys[0] - from.keys[0]
		var art := "slide_up" if step > 0 else "slide_down"
		if step == 0:
			return ""
		if not has_keyswitch(part, art):
			note_fallback(part, "art:slide", BENT)
			return ""
		if has_control(part, "interval_a"):
			_frets(out, part, t, "interval_a", absi(step))
		return art
	if e.scoop and has_keyswitch(part, "slide_in"):
		if has_control(part, "interval_b"):
			_frets(out, part, t, "interval_b", SCOOP_FRETS)
		return "slide_in"
	if e.scoop:
		note_fallback(part, "art:slide", BENT)
	return ""


# The library's interval knobs are split into sixteen-wide bands, one per
# fret count; the middle of a band is the value least likely to be misread.
func _frets(out: Array, part: String, t: float, control: String, frets: int) -> void:
	emit_cc(out, part, t - 0.04, control, mini(frets - 1, 6) * 16 + 8)


# A fall is the finger sliding away down the neck as the note ends: the note
# is let go and the library's glissando tail, played on the same key, takes
# over, lasting until the next note or a short while if nothing follows.
const FALL_LENGTH := 0.4

func _fall(out: Array, part: String, lane: SfzScore.Lane, i: int, t: float,
		spb: float, velocity: int, duration: float) -> void:
	var e: SfzScore.Event = lane.events[i]
	var start := t + duration
	var length := FALL_LENGTH
	if i + 1 < lane.events.size():
		var next: SfzScore.Event = lane.events[i + 1]
		length = minf(length, (next.at - e.at) * spb - duration - 0.01)
	if length <= 0.02:
		return
	emit_art(out, part, start - 0.02, "slide_out")
	for key in e.keys:
		emit_note(out, part, start, key, maxi(velocity - 10, 1), length)


# --- Bends ---------------------------------------------------------------

# A synth has no frets and no slide samples; it has a pitch wheel. On a part
# with no slide articulation the same three marks are played on that instead,
# through the part's "bend" control where the ensemble maps one and the SFZ's own
# pitch wheel where it does not:
#
#   /  slide  this note leaves early and bends toward the next one, so the
#             next lands in tune on its own beat. A player departs early and
#             arrives in tune; the lean is half the gap between the two notes,
#             up to GLIDE_LEAN, and below GLIDE_TIME there is no room for it
#             and the join falls back to the glide below.
#   \  glide  the next note starts at the pitch of this one and travels up or
#             down to its own, quickly - a portamento, longer for a wider
#             leap. This is a mono synth's portamento rather than a player's:
#             the note arrives on the beat out of tune and corrects itself.
#             Everything else about the join is the slide's.
#   <  scoop  the note starts a little under itself and rises into place
#   >  fall   the note drops away as it ends, a few semitones in its last
#             moment, and the wheel is back at rest before anything follows
#
# The wheel is the whole part's, so every gesture
# returns it to the middle, and nothing else ever moves it.
const GLIDE_TIME := 0.06       # seconds for the smallest glide...
const GLIDE_PER_STEP := 0.01   # ...and this much more per semitone
const GLIDE_MAX := 0.14
const GLIDE_LEAN := 0.32       # how long a slide may leave its note early
const SCOOP_CENTS := -150.0
const SCOOP_TIME := 0.13
const FALL_CENTS := -500.0
const FALL_TIME := 0.25
const BEND_STEP := 0.01        # a pitch sweep needs finer steps than a swell

# Parts already told their bend was cut short, so a score says it once.
var _bend_warned: Dictionary = {}
var _title := ""

func _bend(out: Array, part: String, lane: SfzScore.Lane, i: int, t: float,
		spb: float, duration: float, from: SfzScore.Event) -> void:
	var e: SfzScore.Event = lane.events[i]
	if e.keys.is_empty():
		return
	if from != null:
		var step: int = e.keys[0] - from.keys[0]
		if step != 0:
			var span := (e.at - from.at) * spb
			var lead := minf(GLIDE_LEAN, span * 0.5)
			if from.glide or lead < GLIDE_TIME:
				var time := minf(GLIDE_TIME + GLIDE_PER_STEP * absi(step), GLIDE_MAX)
				_sweep(out, part, t, time, -100.0 * step, 0.0)
			else:
				# The wheel carries the OLD note toward this one so that this
				# one arrives in tune, then hands the pitch over. The sweep
				# stops a whole BEND_STEP short because _sweep rounds its last
				# point up to the next step, which would otherwise land on top
				# of - and after - the reset to rest below, leaving the wheel
				# bent for everything that follows.
				_sweep(out, part, t - lead, lead - BEND_STEP * 2.0, 0.0, 100.0 * step)
				_emit_bend(out, part, t - 0.001, 0.0)
	elif e.scoop:
		_sweep(out, part, t, SCOOP_TIME, SCOOP_CENTS, 0.0)
	elif not lane.bend.is_empty():
		_shape(out, part, lane, i, t, spb, duration)
		return
	# A part with slide_out samples falls on those (_fall), not on the wheel too.
	if e.fall and not has_keyswitch(part, "slide_out"):
		var length := FALL_TIME
		var room := INF
		if i + 1 < lane.events.size():
			room = (lane.events[i + 1].at - e.at) * spb
		length = minf(length, duration * 0.5)
		_sweep(out, part, t + duration - length, length, 0.0, FALL_CENTS)
		# Back to rest once the note has faded, or just before the next one.
		_emit_bend(out, part, t + minf(duration + 0.25, room - 0.01), 0.0)


# A written shape (`bend:` on the lane): straight lines between its points,
# from no bend at the note's start, then back to rest once the note has
# faded or just before the next one - the same courtesy as a fall.
func _shape(out: Array, part: String, lane: SfzScore.Lane, i: int, t: float,
		spb: float, duration: float) -> void:
	var at := 0.0
	var cents := 0.0
	for point: Array in lane.bend:
		var to: float = float(point[0]) * spb
		if to > duration:
			break
		if to - at < BEND_STEP:
			_emit_bend(out, part, t + to - 0.001, float(point[1]))
		else:
			_sweep(out, part, t + at, to - at, cents, float(point[1]))
		at = to
		cents = float(point[1])
	var room := INF
	if i + 1 < lane.events.size():
		room = (lane.events[i + 1].at - lane.events[i].at) * spb
	_emit_bend(out, part, t + minf(duration + 0.25, room - 0.01), 0.0)


# A straight line in cents from `a` to `b`, starting at `t`. The first point
# is written a hair before `t` so that it reaches the synth ahead of a note
# starting at the same moment - the note then begins already bent.
func _sweep(out: Array, part: String, t: float, time: float, a: float, b: float) -> void:
	var last := -1
	var x := 0.0
	while true:
		var f := minf(x / time, 1.0)
		var cents := lerpf(a, b, f)
		var value := _bend_value(cents)
		if value != last:
			_emit_bend(out, part, t + x - (0.001 if x == 0.0 else 0.0), cents)
			last = value
		if f >= 1.0:
			break
		x += BEND_STEP


# One point of a bend. A bend goes only as far as bend_reach - the pitch
# wheel's bend_range on a part without a "bend" control, and the control's
# own BEND_RANGE on any part - so anything past that is said once per part
# per score rather than cut short without a word. bend_cut is the threshold
# tools/check.gd reports on too.
func _emit_bend(out: Array, part: String, t: float, cents: float) -> void:
	if ensemble != null and not _bend_warned.has(part) \
			and bend_cut(cents, part_for(part)):
		_bend_warned[part] = true
		var r: SfzEnsemble.Part = part_for(part)
		var how := "its \"bend\" control reaches %d" % int(BEND_RANGE)
		if r.cc("bend") < 0 and r.bend_range <= BEND_RANGE:
			how = "has no \"bend\" control and its pitch wheel reaches %d" % int(bend_reach(r))
		elif r.cc("bend") < 0:
			# The wheel reaches further than the control a bend is written
			# on, so the control's range is where it stops.
			how = "its pitch wheel reaches %d, but the \"bend\" control it is written on %d" % [
				int(r.bend_range), int(BEND_RANGE)]
		push_warning("%s: %s bends %d cents, but %s; the bend stops there" % [
			_title if _title != "" else "score", part, int(round(cents)), how])
	if ensemble != null and on_wheel(part):
		note_fallback(part, "control:bend",
				"its bends go to the pitch wheel, which reaches %d cents" % int(wheel_cents(part)))
	emit_cc(out, part, t, "bend", _bend_value(cents))


# Cents to the control's value: 64 is exactly no bend, and the two halves
# are scaled separately because there are 64 steps below it and 63 above.
func _bend_value(cents: float) -> int:
	var c := clampf(cents / BEND_RANGE, -1.0, 1.0)
	return clampi(64 + int(round(c * (64.0 if c < 0.0 else 63.0))), 0, 127)


# --- Fallbacks -----------------------------------------------------------
#
# What is said, through fell_back, when the ensemble cannot play a mark as
# written (see SfzScoreCompiler.fell_back). Only marks with nothing else to
# carry them are counted: a staccato with no staccato key is still cut short
# by its gate, an accent with no marcato is still louder, and a slur with no
# legato samples still overlaps and softens, so none of those is news.

const FLAT_DYNAMICS := "its ramps and swells are carried on velocity alone"
# A slide, scoop or fall with no slide samples for it: the pitch wheel plays
# it instead (see _bend), which is said as its own item where that wheel is
# all the part has.
const BENT := "its slides, scoops and falls are bent instead"


# --- Small helpers -------------------------------------------------------

func _level(name: String, fallback: int) -> int:
	if name == "":
		return fallback
	return int(SfzScore.DYNAMICS.get(name, fallback))


func _across(at: float, beats: float) -> float:
	if beats <= 0.0:
		return 0.0
	return clampf(at / beats, 0.0, 1.0)
