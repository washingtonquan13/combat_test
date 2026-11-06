class_name SfzTimeline
extends RefCounted

# A compiled event, resolved for the instruments that play it.
#
# A score event names a part; an instrument hears keys, controls and the
# wheel. Between the two are the ensemble's rules - the fold into the part's
# range, each layer's transpose, velocity window, delay, keyswitches and
# controls, the drum map - and this is where they are applied, once, for the
# whole piece, at prepare (SfzScorePlayer._build). What comes out is rows:
# one per instrument-level event, as the timeline cursor plays them
# (native/src/timeline.h, interface A).
#
# Times are integer frames at the playback rate, converted from seconds with
# roundi(), which is llround() - what SfzInstrumentPlayback::schedule() does.
# A row's frame is `when`, BEFORE the take: the cursor adds the take, read at
# the row's piece frame (SfzEnsemble.take_frames()).

# timeline.h's TimelineClass.
const NOTE_ON := 0
const NOTE_OFF := 1
const CC := 2
const ART_ON := 3
const WHEEL := 4
const HIT := 5
const FIXED_OFF := 6

const NO_TAKE := 255
const EVERY_LEVEL := 255

# timeline.h's decision ops (SfzInstrument.decide(), SfzOfflineRenderer.decide()).
const OP_PLAY := 0x10
const OP_LEAVE := 0x11
const OP_SET_LEVEL := 0x12
const OP_STOP := 0x13

# timeline.h's TimelineReport kinds, as poll_timeline() returns them.
const REPORT_PASS_STARTED := 1
const REPORT_LANDED := 2
const REPORT_LEFT := 3
const REPORT_ENDED := 4
const REPORT_STARVED := 5

# Timeline slots per instrument.
const SLOTS := 8

# A drum key is a one-shot: its note off is a formality that frees the voice,
# so it trails the hit rather than the grid.
const HIT_LIFT := 0.05
# A keyswitch is held briefly rather than pulsed, because sfizz latches on
# sw_last and a zero-length tap is a race.
const TAP := 0.02

# One row: [layer index in the part's stack, cls, a, b, when, shift, take].
# `take` is whether the layer's take moves it; `shift` is when - written end
# for a NOTE_OFF, 0 otherwise.
const ROW_LAYER := 0
const ROW_CLS := 1
const ROW_A := 2
const ROW_B := 3
const ROW_WHEN := 4
const ROW_SHIFT := 5
const ROW_TAKE := 6


# What `event` (a compiled score event, at its written time) becomes on
# `part`'s layers, in the order the conductor used to send it: a note's
# presses, layer by layer, then its releases; a hit's press and lift, layer
# by layer; a keyswitch's tap and lift, layer by layer; a control or a bend,
# layer by layer. A row the layer would not take is not made: a velocity
# outside its window, a drum the kit does not map, an articulation or a
# control it has no key or number for. Keys unloaded on an instrument are
# the caller's to check, since only a loaded conductor knows them.
static func rows_of(event: Dictionary, part: SfzEnsemble.Part, rate: float) -> Array:
	var rows: Array = []
	var s := float(event["t"])
	var layers := part.layers
	match event["kind"]:
		"note":
			var velocity := int(event["velocity"])
			var duration := float(event["duration"])
			var folded := part.fit(int(event["key"]))
			var offs: Array = []
			for li in layers.size():
				var layer: SfzEnsemble.Layer = layers[li]
				if not layer.takes(velocity):
					continue
				var pitch := clampi(folded + layer.transpose, 0, 127)
				var take := layer.has_take()
				rows.append([li, NOTE_ON, pitch, clampi(velocity, 1, 127),
					roundi((s + layer.delay) * rate), 0, take])
				var off_when := roundi((s + layer.delay + duration) * rate)
				offs.append([li, NOTE_OFF, pitch, 0, off_when,
					off_when - roundi((s + duration) * rate), take])
			rows.append_array(offs)
		"hit":
			var velocity := int(event["velocity"])
			var key := part.key_for(event["drum"])
			if key < 0:
				return rows
			# Transpose is ignored: a drum key is a name in a map rather than a
			# pitch, and moving it would fetch a different instrument.
			for li in layers.size():
				var layer: SfzEnsemble.Layer = layers[li]
				if not layer.takes(velocity):
					continue
				var take := layer.has_take()
				rows.append([li, HIT, key, clampi(velocity, 1, 127),
					roundi((s + layer.delay) * rate), 0, take])
				rows.append([li, FIXED_OFF, key, 0,
					roundi((s + layer.delay + HIT_LIFT) * rate), 0, take])
		"art":
			var fallback := part.keyswitch(event["art"])
			for li in layers.size():
				var key := (layers[li] as SfzEnsemble.Layer).keyswitch(event["art"], fallback)
				if key < 0:
					continue
				rows.append([li, ART_ON, key, 100, roundi(s * rate), 0, false])
				rows.append([li, FIXED_OFF, key, 0, roundi((s + TAP) * rate), 0, false])
		"cc":
			var control: String = event["control"]
			var number := part.cc(control)
			var when := roundi(s * rate)
			if number < 0 and control == "bend":
				# No control of its own: the SFZ's pitch wheel plays the same
				# bend, as far as the wheel goes.
				var wheel := wheel_bits(SfzScoreCompiler.wheel_value(int(event["value"]),
					part.bend_range))
				for li in layers.size():
					rows.append([li, WHEEL, wheel & 127, wheel >> 7, when, 0, false])
				return rows
			var value := clampi(int(event["value"]), 0, 127)
			for li in layers.size():
				var on := (layers[li] as SfzEnsemble.Layer).cc(control, number)
				if on >= 0:
					rows.append([li, CC, on, value, when, 0, false])
	return rows


# A signed wheel value, -8192..8191, as the fourteen bits a row carries.
static func wheel_bits(value: int) -> int:
	return clampi(value, -8192, 8191) + 8192


# Where `control` rests on `part`'s layer `li`, as [cls, a, value] - a CC's
# number and value, or the wheel's fourteen bits - or [] when the layer does
# not hear it. `rest` is the score's resting value, 0..127.
static func rest_of(part: SfzEnsemble.Part, li: int, control: String, rest: int) -> Array:
	var number := part.cc(control)
	if number < 0 and control == "bend":
		return [WHEEL, 0, wheel_bits(SfzScoreCompiler.wheel_value(rest, part.bend_range))]
	var on := (part.layers[li] as SfzEnsemble.Layer).cc(control, number)
	if on < 0:
		return []
	return [CC, on, clampi(rest, 0, 127)]
