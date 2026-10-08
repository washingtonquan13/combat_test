class_name SfzScoreCompiler
extends RefCounted

# Turns a Score into a flat, time-sorted list of things to do.
#
# This is the literal compiler: a note written as `d4:2` becomes exactly one
# note_on at beat 0 of the bar, at the velocity its dynamic marking asks for,
# and nothing else. No timing humanization, no velocity shaping across a
# phrase, no legato, no CC curves. The lane's `feel`, `vib` and dynamic ramps
# are read, carried, and deliberately ignored.
#
# It exists so that Performance, which overrides compile(), has something to
# be compared against. Same score, same ensemble, same scheduler, same meters -
# the only difference is this class. That difference is the measure of what
# performance data is worth.
#
# The output is an Array of Dictionaries, each with "kind" and "t" (seconds
# from the top of the piece) plus whatever that kind needs:
#
#   {kind="note", part, key, velocity, duration}
#   {kind="hit",  part, drum, velocity}
#   {kind="cc",   part, control, value}
#   {kind="art",  part, art}
#
# "part" is the score's part, as its `parts:` header names it; which of the
# ensemble's parts plays it is SfzEnsemble.resolve's answer, asked once per
# compile (_cast) and again by the player that sends them.
#
# and every one of them also carries "section": its entry's index in the
# score's timeline, which is how a player finds the loop in a flat list whose
# setup points and pushed notes land a little before their section starts.
#
# and every one of them also carries "perf": the lane's performance name
# (SfzScore.Lane.name - "lead.harmony", "perc"), so a report or an export can
# say which line of the part an event came from.
#
# A lane in an intensity layer also tags its events "layer": [lowest,
# highest], the levels it plays at. The compiler plays every lane; which of
# them is heard is the player's to decide, at the moment it sends them.

# Lane-level settings are placed this far before the music they colour, so
# they are in effect for its first note without landing on top of it.
const SETUP_LEAD := 0.01

var ensemble: SfzEnsemble

# Which pass of the loop each timeline entry belongs to, indexed by the
# entry's position in score.timeline(). Entries past the end of this array,
# and every entry when it is empty, are pass 0.
#
# A looping piece is compiled with the loop written more than once so that
# what repeats was performed coming out of a pass rather than out of the
# intro. Those copies are the same sections in the same order, so a compiler
# that seeds from the music alone performs them identically and the loop is
# bit-identical every time round - which is what a game's music sounding
# like a tape loop actually is. This is how a player says "and this copy is
# a different time through", without saying anything about what should
# differ. The literal compiler has nothing to vary and ignores it.
var pass_of := PackedInt32Array()

# What the last compile() played some other way than written because the
# ensemble could not play it as written, and so never put in its output: a mute
# with no mute samples played on the staccato key, a crescendo with no
# dynamics control left to velocity, a bend sent to the pitch wheel. Keyed
# "part|item", each {part, item, count, fallback}: count is how many times,
# fallback what was done instead. Emptied at the top of every compile().
#
# The plan cannot say these, because a fallback leaves nothing behind in it
# to find - which is exactly why the player cannot work them out for itself.
# SfzScorePlayer._report reads this after compiling and says each one once,
# with the drops it finds in the plan (see the per-ensemble warnings, GOALS §6).
var fell_back: Dictionary = {}

# The score's parts resolved against the ensemble, as SfzEnsemble.cast gives it:
# score part -> {part, step}. Set at the top of every compile(); every query
# below asks the ensemble part it names.
var _cast: Dictionary = {}


# The pass a timeline entry belongs to.
func pass_at(at: int) -> int:
	return pass_of[at] if at < pass_of.size() else 0


func _init(new_ensemble: SfzEnsemble = null) -> void:
	ensemble = new_ensemble


# What this compiler did, for the test's report line.
func describe() -> String:
	return "literal"


func compile(score: SfzScore) -> Array:
	var out: Array = []
	fell_back = {}
	cast_for(score)
	var timeline := score.timeline()
	for at in timeline.size():
		var entry: Dictionary = timeline[at]
		var section_first := out.size()
		var section: SfzScore.Section = score.sections[entry["name"]]
		var origin: float = entry["at"]
		var spb: float = 60.0 / float(entry["bpm"])

		for name in section.lanes:
			var lane: SfzScore.Lane = section.lanes[name]
			var part := lane.part
			var base := lane.base_velocity()
			var first := out.size()

			# Lane intent the runtime can honour without interpreting: the
			# articulation keyswitch, and one flat dynamics level. The key is
			# asked of the part the lane plays, as the performance compiler
			# asks it: a part whose layers lack it is sent nothing. With no
			# ensemble to ask, the lane's word is taken as written.
			if lane.art != "" and (ensemble == null or has_keyswitch(part, lane.art)):
				emit_art(out, part, origin - SETUP_LEAD, lane.art)
			elif lane.art != "" and _sounds(lane):
				note_fallback(part, "art:" + lane.art, KEEPS_ART, lane.name)
			# Asked first, as the performance compiler asks: a level for a part
			# that has no dynamics knob is an event nobody hears, and in a MIDI
			# export a controller change aimed at nothing.
			if has_control(part, "dynamics"):
				emit_cc(out, part, origin - SETUP_LEAD, "dynamics", cc_from_velocity(base))

			for item in lane.events:
				var e: SfzScore.Event = item
				var t: float = origin + e.at * spb
				var velocity := e.velocity(base)
				if not e.drum.is_empty():
					emit_hit(out, part, t, e.drum, velocity)
					continue
				var duration: float = e.sounding_duration() * spb
				for key in e.keys:
					emit_note(out, part, t, key, velocity, duration)
			tag_lane(out, first, lane)
		tag_section(out, section_first, at)

	return sorted(out)


# --- Emitters ------------------------------------------------------------
#
# Subclasses build the same four kinds of event, so they are written once.
# Every one of them is a plain append; the sort at the end is what puts the
# piece in order, which means a compiler may emit in whatever order is
# convenient to reason about.

func emit_note(out: Array, part: String, t: float, key: int, velocity: int,
		duration: float) -> void:
	out.append({
		"kind": "note", "t": t, "part": part,
		"key": key, "velocity": velocity, "duration": duration,
	})


func emit_hit(out: Array, part: String, t: float, drum: String, velocity: int) -> void:
	out.append({
		"kind": "hit", "t": t, "part": part, "drum": drum, "velocity": velocity,
	})


func emit_cc(out: Array, part: String, t: float, control: String, value: int) -> void:
	out.append({
		"kind": "cc", "t": t, "part": part,
		"control": control, "value": clampi(value, 0, 127),
	})


func emit_art(out: Array, part: String, t: float, art: String) -> void:
	out.append({"kind": "art", "t": t, "part": part, "art": art})


# --- Shared helpers ------------------------------------------------------

# The fallback for an articulation nobody can switch to: the conductor sends
# a keyswitch only to a layer that has the key, so the others play on in
# whatever they were last given.
const KEEPS_ART := "keeps the articulation it already has"

# Counts one fallback into fell_back, for the score part `part`. `lane` is the
# performance name of the lane that asked, so the warning can name the lanes
# that lack something; left empty it is the part's own name.
func note_fallback(part: String, item: String, fallback: String, lane: String = "") -> void:
	var key := "%s|%s" % [part, item]
	var entry: Dictionary = fell_back.get(key, {})
	if entry.is_empty():
		entry = {"part": part, "item": item, "count": 0, "fallback": fallback, "lanes": []}
		fell_back[key] = entry
	entry["count"] += 1
	if lane == "":
		lane = part
	if not lane in entry["lanes"]:
		entry["lanes"].append(lane)


# Whether a lane plays anything: a lane of rests asks for nothing to be
# heard, so a missing articulation on it is not news.
static func _sounds(lane: SfzScore.Lane) -> bool:
	for e: SfzScore.Event in lane.events:
		if not e.is_rest():
			return true
	return false


# Marks everything a section emitted, from index `first` on, with its place
# in the timeline.
func tag_section(out: Array, first: int, at: int) -> void:
	for i in range(first, out.size()):
		out[i]["section"] = at

# Marks everything a lane emitted, from index `first` on, with its
# performance name. Done once per lane rather than in every emitter, so an
# emitter never needs to know which lane is calling it.
func tag_lane(out: Array, first: int, lane: SfzScore.Lane) -> void:
	for i in range(first, out.size()):
		out[i]["perf"] = lane.name
		if not lane.layer.is_empty():
			out[i]["layer"] = lane.layer


# Resolves `score`'s parts against the ensemble, for the queries below. compile()
# calls it; a caller asking those questions without compiling calls it first.
func cast_for(score: SfzScore) -> void:
	_cast = {} if ensemble == null else ensemble.cast(score.parts)


# The ensemble part that plays the score's part `part`: its cast, or with no
# cast (a query made before any compile) the ensemble part of that name. An
# empty part - no layers - for one that resolved to nothing.
func part_for(part: String) -> SfzEnsemble.Part:
	if _cast.has(part):
		return ensemble.part(_cast[part]["part"])
	return ensemble.part(part)


# Whether a control written on a lane of `part` reaches an instrument.
# Asking before writing a curve is not about correctness - the Conductor
# drops unmapped controls safely - it is about not spending scheduler queue
# on events nobody hears.
#
# Asked of the part the lane is cast on (SfzEnsemble.Part.hears), so a part whose
# layers have no knob for a control is not written a curve, and a part with no
# layers is written nothing, not even a bend. It is the rule
# check.gd and render.gd's tables share: a layer that reads the control on a
# number of its own counts even where the part names none, and "bend" is
# always heard, on the pitch wheel where there is no control for it. Whether a
# bend is on the wheel is on_wheel(), not this.
func has_control(part: String, control: String) -> bool:
	if ensemble == null:
		return false
	var cast := part_for(part)
	return not cast.layers.is_empty() and cast.hears(control)


# Whether this part's bends go to the SFZ's pitch wheel rather than a control
# of its own: the conductor's test (conductor.gd, cc()), which asks the part's
# own number alone, so the wheel's reach is what limits the bend.
func on_wheel(part: String) -> bool:
	if ensemble == null:
		return true
	return part_for(part).cc("bend") < 0


# Whether a part can bend at all. Every one can: on its own "bend" control
# where the ensemble maps one, and otherwise on the pitch wheel every SFZ
# answers, which the conductor turns that same control into. Only a missing
# ensemble has nobody to ask.
func can_bend(_part: String) -> bool:
	return ensemble != null


# The "bend" control reaches this far either side of its middle, 64...
const BEND_RANGE := 1200.0
# ...and the pitch wheel only as far as the part's bend_range: sfizz's default
# bend_up/bend_down of 200 unless the registry or the ensemble says its SFZ
# sets them otherwise. A bend deeper than that on a part without its own
# control stops at the end.
const WHEEL_CENTS := 200.0


func wheel_cents(part: String) -> float:
	if ensemble == null:
		return WHEEL_CENTS
	return part_for(part).bend_range


# How far a bend written for `part` can actually go, in cents either way.
# Two limits, and the nearer one wins: the "bend" control's value is clamped
# to BEND_RANGE when it is written (SfzPerformanceCompiler._bend_value), for
# every part; and a part with no control of its own is then played on the
# pitch wheel, which stops at its bend_range (wheel_value clamps there).
static func bend_reach(part: SfzEnsemble.Part) -> float:
	if part.cc("bend") >= 0:
		return BEND_RANGE
	return minf(part.bend_range, BEND_RANGE)


# A written bend is cut short when it goes past bend_reach by more than
# this. Half a cent is float slack, not musical slack: a bend written at
# exactly the reach is not a cut. The one threshold for the question - the
# compiler's warning (SfzPerformanceCompiler._emit_bend) and tools/check.gd's
# bend remark both call bend_cut, so they cannot disagree about a 205-cent
# bend on a 200-cent wheel.
const BEND_SLACK := 0.5

static func bend_cut(cents: float, part: SfzEnsemble.Part) -> bool:
	return absf(cents) > bend_reach(part) + BEND_SLACK


# A "bend" control value, 0..127, as a pitch wheel position, -8192..8191:
# the same cents, as far as the wheel reaches.
static func wheel_value(bend: int, reach: float = WHEEL_CENTS) -> int:
	var c := float(clampi(bend, 0, 127) - 64)
	var cents := BEND_RANGE * c / (64.0 if c < 0.0 else 63.0)
	return clampi(int(round(cents / reach * 8192.0)), -8192, 8191)


# Whether `part` has samples for an articulation: its layers are asked
# (Part.switches, the conductor's own rule). One question for every use - the
# keyswitch sent, and the gestures that choose between a key and something
# else (a slide or a bend, a fall's slide_out, the legato lift). A part whose
# layers have no slide keys is not sent a slide it cannot play, and keeps the
# bend it can.
func has_keyswitch(part: String, art: String) -> bool:
	if ensemble == null or art == "":
		return false
	return part_for(part).switches(art)


# Whether a note on this part that runs into the next one is cut off by its
# own release (SfzEnsemble.Part.cuts_on_release).
func release_cuts(part: String) -> bool:
	if ensemble == null:
		return false
	return part_for(part).cuts_on_release()


# The drum that plays `key` dead on this part - the string damped by the
# fretting hand, the pitch gone - or "" where the part has no such sounds.
# A library that records dead notes as one noise per string (Swag Bass) is
# mapped with drums named dead_<open string>, so the part's drum map says
# both which strings there are and where each one's thud sits. A note is on
# the highest string whose open pitch is at or under it, which is the string
# a player in the lowest position would fret it on; a note under every string
# goes to the lowest one.
func dead_string(part: String, key: int) -> String:
	if ensemble == null:
		return ""
	var on := ""
	var on_open := -1
	var lowest := ""
	var lowest_open := 128
	for drum: String in part_for(part).drums:
		if not drum.begins_with("dead_"):
			continue
		var open := SfzScore.parse_note(drum.substr(5))
		if open < 0:
			continue
		if open <= key and open > on_open:
			on = drum
			on_open = open
		if open < lowest_open:
			lowest = drum
			lowest_open = open
	return on if on != "" else lowest


# The articulation a part plays when nothing asks for another, as the ensemble
# names it; "" if the ensemble has none.
func resting_art(part: String) -> String:
	if ensemble == null:
		return ""
	return part_for(part).keyswitch_default


# The ensemble's own resting value for a control, which is where a curve should
# start and where it should return to.
func default_for(part: String, control: String, fallback: int) -> int:
	if ensemble == null:
		return fallback
	return int(part_for(part).defaults.get(control, fallback))


# A dynamic marking is a velocity; most libraries also want it as a
# continuous controller. fff (122) is full scale, not 127, because the
# accents have to have somewhere to go.
func cc_from_velocity(velocity: int) -> int:
	return clampi(int(round(velocity * 127.0 / 122.0)), 0, 127)


# By time, and stably: two events at the same instant keep the order they
# were emitted in. Godot's sort_custom is not stable, and for events that
# order is part of the meaning - a lane's opening CC1 is emitted before its
# first note so the note speaks at the level it was written at. Unstable, the
# tie went whichever way the sort happened to fall, which moved whenever
# anything was added anywhere else in the score: a synth lead written into
# its own section, seconds later, changed how the pad at the top started.
#
# Sorted as [t, index] pairs by the native sort rather than sort_custom: arrays
# compare element by element, so the index is the same tiebreak, and a
# GDScript lambda called per comparison was most of the cost of a load.
func sorted(out: Array) -> Array:
	var order: Array = []
	order.resize(out.size())
	for i in out.size():
		order[i] = [float(out[i]["t"]), i]
	order.sort()
	var result: Array = []
	result.resize(out.size())
	for i in order.size():
		result[i] = out[order[i][1]]
	return result
