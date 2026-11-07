class_name SfzMidiExport
extends RefCounted

# Writes a score out as a Standard MIDI File, for taking a piece into a DAW,
# showing it to someone who does not read .score, or checking by eye what the
# performance compiler did to it.
#
# It exports what the engine plays, not what the score says, which is the
# direction MIDI is honest in: a MIDI file stores what happened. The events
# come from the same compiler the game uses (the performance one by default),
# so the pushed beats, the shaped velocities, the slur overlaps and the CC
# curves are all in the file. The literal compiler is there for a file that
# lines up on the grid.
#
# The layout:
#
#   * One track per lane performance name - lead, lead.high, perc.feet - each
#     on a channel of its own, and every lane of a perc-family part on channel
#     10 as a DAW expects.
#     Track 0 holds the tempo map, the meter, the key and a marker at the top
#     of every section, plus `loopStart` and `loopEnd` where a looping score
#     loops, which is the convention most game audio tools read.
#   * Named controls become the CC numbers the ensemble gives them - those of
#     the layers of the part the lane is cast on, a layer's own where it names one,
#     every distinct one where they differ, as the Conductor sends them -
#     drums become the ensemble's keys, and an articulation is its keyswitch,
#     tapped the way the Conductor taps it (on the primary layer's key where
#     the part has none: one track cannot tap two libraries' keys at once). So the file plays correctly through the same SFZ
#     libraries in any sampler. Through anything else, the keyswitches are
#     low notes you will want to delete, and `keyswitches = false` leaves them
#     out.
#   * Notes are written at the pitch the library plays, folded into its range
#     the way the Conductor folds them.
#
# What it leaves out, because it belongs to a layer and not to the part: each
# layer's transpose, delay and take wander. Those are the sound, and the file
# is the performance.
#
#   var export := SfzMidiExport.new()
#   var err := export.write(score, ensemble, "user://battle.mid")

const PPQ := 960
const DRUM_CHANNEL := 9
# The Conductor holds a drum hit and a keyswitch tap this long.
const HIT_LENGTH := 0.05
const TAP_LENGTH := 0.02
const TAP_VELOCITY := 100

# Major keys by pitch class, as sharps (negative for flats). A minor key has
# its relative major's signature.
const SIGNATURE := [0, -5, 2, -3, 4, -1, 6, 1, -4, 3, -2, 5]

var compiler: SfzScoreCompiler = SfzPerformanceCompiler.new()
var keyswitches := true

# After write(): what went into the file, and what could not.
var notes := 0
var controls := 0
var skipped: Array[String] = []  # "part/control" and "part/drum" with nothing mapped
var tracks: Array[String] = []   # track names in file order, the tempo track first


# The whole job from paths, for the command line and the editor menu: parses
# the score, loads its ensemble (or `ensemble_id`) and writes `out_path`. Returns ""
# when it worked, otherwise what went wrong.
func write_file(score_path: String, out_path: String, ensemble_id := "") -> String:
	var file := FileAccess.open(score_path, FileAccess.READ)
	if file == null:
		return "cannot read %s" % score_path
	var parser := SfzScoreParser.new()
	var score := parser.parse(file.get_as_text(), score_path)
	if score == null:
		return "\n".join(parser.errors)
	var id := ensemble_id if ensemble_id != "" else score.ensemble_id
	if id == "":
		return "%s names no ensemble: header; say which with --ensemble" % score_path
	var ensemble := SfzEnsemble.load_from(SfzSettings.ensemble_path(id))
	if ensemble == null:
		return "cannot load ensemble '%s' from %s" % [id, SfzSettings.ensemble_path(id)]
	var err := write(score, ensemble, out_path)
	if err != OK:
		return "cannot write %s: %s" % [out_path, error_string(err)]
	return ""


# One line on what the last write put in the file.
func summary() -> String:
	var line := "%d notes, %d controller changes, %d tracks (%s)" % [
		notes, controls, tracks.size(), ", ".join(tracks.slice(1))]
	if not skipped.is_empty():
		line += "; nothing in the ensemble for %s" % ", ".join(skipped)
	return line


# Returns OK, or the error the file could not be opened with.
func write(score: SfzScore, ensemble: SfzEnsemble, path: String) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(build(score, ensemble))
	file.close()
	return OK


# The whole file, as bytes.
func build(score: SfzScore, ensemble: SfzEnsemble) -> PackedByteArray:
	notes = 0
	controls = 0
	skipped.clear()
	tracks.clear()

	compiler.ensemble = ensemble
	var timeline := score.timeline()
	var events := compiler.compile(score)
	var ticks_per_beat := PPQ * 4.0 / score.beat_unit
	var cast := ensemble.cast(score.parts)

	# Every lane that says anything gets a track, bus by bus in BUSES order and
	# by name within a bus, so the file reads top to bottom the way the ensemble
	# does. The bus is that of the part the lane is cast on, or for one cast on
	# nothing its family's base; a lane of a perc-family part is on the
	# drum channel whatever it is cast on, since its notes are drum names.
	var parts := {}
	for event: Dictionary in events:
		var id := _part_id(event)
		if not parts.has(id):
			var score_part: String = event["part"]
			var family: String = score.parts.get(score_part, {}).get("family", score_part)
			var cast_as: String = cast.get(score_part, {"part": score_part})["part"]
			var bus: String = ensemble.part(cast_as).bus if cast_as != "" else ""
			if bus == "":
				bus = SfzEnsemble.base_family(family)
			parts[id] = {"bus": bus, "drums": SfzEnsemble.base_family(family) == "perc",
				"cast": cast_as, "items": [], "notes": []}
	var ids: Array = parts.keys()
	ids.sort_custom(func(a, b):
		var ra := SfzEnsemble.BUSES.find(parts[a]["bus"])
		var rb := SfzEnsemble.BUSES.find(parts[b]["bus"])
		return ra < rb or (ra == rb and a < b))
	var channel := 0
	for id in ids:
		if parts[id]["drums"]:
			parts[id]["channel"] = DRUM_CHANNEL
			continue
		if channel == DRUM_CHANNEL:
			channel += 1
		parts[id]["channel"] = mini(channel, 15)
		channel += 1

	var tick := func(t: float) -> int:
		return _tick(timeline, ticks_per_beat, t)

	# Items are [tick, order, bytes]: at one tick a note off goes before
	# anything else, so a repeated note is let go before it is struck again,
	# and controls before note ons, so a note speaks at the level set for it.
	var seen := {}
	for event: Dictionary in events:
		var part: Dictionary = parts[_part_id(event)]
		var cast_part := ensemble.part(part["cast"])
		var ch: int = part["channel"]
		var t: float = maxf(float(event["t"]), 0.0)
		match event["kind"]:
			"note":
				var key := cast_part.fit(int(event["key"]))
				_note(part, ch, key, int(event["velocity"]), tick.call(t),
					tick.call(t + float(event["duration"])))
			"hit":
				var key := cast_part.key_for(event["drum"])
				if key < 0:
					_skip(seen, "%s/%s" % [event["part"], event["drum"]])
					continue
				_note(part, ch, key, int(event["velocity"]), tick.call(t),
					tick.call(t + HIT_LENGTH))
			"cc":
				var number := cast_part.cc(event["control"])
				if number < 0 and event["control"] == "bend":
					# Played on the pitch wheel, as the conductor plays it. The
					# wheel's reach goes first, as RPN 0, so a receiver bends as
					# far as sfizz does rather than its own default.
					if not part.has("wheel_range"):
						part["wheel_range"] = true
						var reach := int(round(cast_part.bend_range))
						var rpn := [[101, 0], [100, 0], [6, mini(reach / 100, 127)],
								[38, reach % 100], [101, 127], [100, 127]]
						# The sort is not stable, so each step has its own order,
						# all ahead of anything else at the top.
						for n in rpn.size():
							part["items"].append([0, 0.5 + 0.01 * n,
								PackedByteArray([0xB0 | ch, rpn[n][0], rpn[n][1]])])
					var wheel := SfzScoreCompiler.wheel_value(int(event["value"]), cast_part.bend_range) + 8192
					part["items"].append([tick.call(t), 1,
						PackedByteArray([0xE0 | ch, wheel & 0x7f, (wheel >> 7) & 0x7f])])
					controls += 1
					continue
				# Each number the part's layers read it on, as the conductor
				# sends it: each on its own number where it names one and on
				# the part's where it does not. A stack whose layers disagree
				# gets both, in manifest order, so the file drives every
				# library the part is played on.
				var numbers: Array[int] = []
				for layer: SfzEnsemble.Layer in cast_part.layers:
					var on: int = layer.cc(event["control"], number)
					if on >= 0 and not numbers.has(on):
						numbers.append(on)
				if numbers.is_empty():
					_skip(seen, "%s/%s" % [event["part"], event["control"]])
					continue
				for on in numbers:
					part["items"].append([tick.call(t), 1,
						PackedByteArray([0xB0 | ch, on, int(event["value"])])])
					controls += 1
			"art":
				# The part's key, or the primary layer's where the stack
				# carries its own: one track cannot tap two libraries'
				# different keys at once, and the primary is the instrument
				# a reader would say the part is played on.
				var key := cast_part.keyswitch(event["art"])
				if key < 0 and not cast_part.layers.is_empty():
					key = cast_part.primary().keyswitch(event["art"], -1)
				if key < 0 or not keyswitches:
					continue
				_note(part, ch, key, TAP_VELOCITY, tick.call(t), tick.call(t + TAP_LENGTH))

	var out := PackedByteArray()
	out.append_array("MThd".to_ascii_buffer())
	out.append_array(_u32(6))
	out.append_array(_u16(1))
	out.append_array(_u16(ids.size() + 1))
	out.append_array(_u16(PPQ))
	out.append_array(_track(_conductor_track(score, timeline, ticks_per_beat)))
	tracks.append(score.title if score.title != "" else "tempo")
	for id in ids:
		var part: Dictionary = parts[id]
		_place_notes(part)
		var items: Array = part["items"]
		items.push_front([0, -1, _meta(0x03, id.to_utf8_buffer())])
		out.append_array(_track(items))
		tracks.append(id)
	return out


# A track is a lane's performance name: `lead`, `lead.high`, `perc.feet` -
# on a migrated score the name its voice had, so the tracks do not move.
func _part_id(event: Dictionary) -> String:
	return event.get("perf", event["part"])


func _skip(seen: Dictionary, what: String) -> void:
	if not seen.has(what):
		seen[what] = true
		skipped.append(what)


func _note(part: Dictionary, ch: int, key: int, velocity: int, on: int, off: int) -> void:
	part["notes"].append([on, maxi(off, on + 1), ch, key, clampi(velocity, 1, 127)])
	notes += 1


# MIDI has one of each key per channel. The compiler overlaps a slurred note
# into the next on purpose, and when the next is the same key, the first
# one's off would land after the second one's on and cut it short. So a key
# struck while it is still down is let go at that instant instead.
func _place_notes(part: Dictionary) -> void:
	var by_key := {}
	for note: Array in part["notes"]:
		var tag := "%d/%d" % [note[2], note[3]]
		if not by_key.has(tag):
			by_key[tag] = []
		by_key[tag].append(note)
	for tag in by_key:
		var list: Array = by_key[tag]
		list.sort_custom(func(a, b): return a[0] < b[0])
		for i in range(1, list.size()):
			if list[i - 1][0] == list[i][0]:
				# Struck twice at once is struck once, as hard as the harder.
				list[i][4] = maxi(list[i][4], list[i - 1][4])
				list[i][1] = maxi(list[i][1], list[i - 1][1])
				list[i - 1][0] = -1
			elif list[i - 1][1] > list[i][0]:
				list[i - 1][1] = list[i][0]
	var items: Array = part["items"]
	for note: Array in part["notes"]:
		if note[0] < 0:
			continue
		items.append([note[0], 2, PackedByteArray([0x90 | note[2], note[3], note[4]])])
		items.append([note[1], 0, PackedByteArray([0x80 | note[2], note[3], 0])])
	items.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))


func _conductor_track(score: SfzScore, timeline: Array, ticks_per_beat: float) -> Array:
	var items: Array = []
	if score.title != "":
		items.append([0, -1, _meta(0x03, score.title.to_utf8_buffer())])
	var denominator_power := int(round(log(score.beat_unit) / log(2.0)))
	items.append([0, -1, _meta(0x58, PackedByteArray([score.beats_per_bar,
		denominator_power, 24, 8]))])
	var major_root := score.key_root
	var minor := score.key_mode == "minor"
	if minor:
		major_root = (major_root + 3) % 12
	if minor or score.key_mode == "major":
		var sf: int = SIGNATURE[major_root]
		items.append([0, -1, _meta(0x59, PackedByteArray([sf & 0xFF, 1 if minor else 0]))])
	var bpm := -1.0
	for i in timeline.size():
		var entry: Dictionary = timeline[i]
		var at := _tick(timeline, ticks_per_beat, float(entry["at"]))
		if float(entry["bpm"]) != bpm:
			bpm = float(entry["bpm"])
			# MIDI tempo is per quarter note; a score's is per beat.
			var quarter := 60000000.0 / bpm * score.beat_unit / 4.0
			var us := int(round(quarter))
			items.append([at, 0, _meta(0x51, PackedByteArray([
				(us >> 16) & 0xFF, (us >> 8) & 0xFF, us & 0xFF]))])
		items.append([at, 1, _meta(0x06, String(entry["name"]).to_utf8_buffer())])
		if score.has_loop() and i == score.loop_from:
			items.append([at, 2, _meta(0x06, "loopStart".to_utf8_buffer())])
	if score.has_loop():
		var end := _tick(timeline, ticks_per_beat, score.loop_end())
		items.append([end, -2, _meta(0x06, "loopEnd".to_utf8_buffer())])
	var last: Dictionary = timeline[timeline.size() - 1]
	items.append([_tick(timeline, ticks_per_beat, float(last["at"]) + float(last["length"])),
		3, PackedByteArray()])
	items.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	return items


# Seconds to ticks through the tempo map: a section's own tempo from where it
# starts. Past the end, the last section's tempo carries on.
func _tick(timeline: Array, ticks_per_beat: float, t: float) -> int:
	var base := 0.0
	for i in timeline.size():
		var entry: Dictionary = timeline[i]
		var at := float(entry["at"])
		var beats_per_second := float(entry["bpm"]) / 60.0
		var last := i == timeline.size() - 1
		if last or t < at + float(entry["length"]):
			return int(round(base + (t - at) * beats_per_second * ticks_per_beat))
		base += float(entry["length"]) * beats_per_second * ticks_per_beat
	return 0


func _meta(kind: int, data: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray([0xFF, kind])
	out.append_array(_vlq(data.size()))
	out.append_array(data)
	return out


# An item with empty bytes is only a place in time: the end of the track.
func _track(items: Array) -> PackedByteArray:
	var body := PackedByteArray()
	var now := 0
	for item: Array in items:
		var bytes: PackedByteArray = item[2]
		if bytes.is_empty():
			continue
		body.append_array(_vlq(maxi(int(item[0]) - now, 0)))
		now = maxi(int(item[0]), now)
		body.append_array(bytes)
	var end := now
	for item: Array in items:
		end = maxi(end, int(item[0]))
	body.append_array(_vlq(end - now))
	body.append_array(PackedByteArray([0xFF, 0x2F, 0x00]))
	var out := "MTrk".to_ascii_buffer()
	out.append_array(_u32(body.size()))
	out.append_array(body)
	return out


func _vlq(value: int) -> PackedByteArray:
	var out := PackedByteArray([value & 0x7F])
	value >>= 7
	while value > 0:
		out.insert(0, (value & 0x7F) | 0x80)
		value >>= 7
	return out


func _u32(value: int) -> PackedByteArray:
	return PackedByteArray([(value >> 24) & 0xFF, (value >> 16) & 0xFF,
		(value >> 8) & 0xFF, value & 0xFF])


func _u16(value: int) -> PackedByteArray:
	return PackedByteArray([(value >> 8) & 0xFF, value & 0xFF])
