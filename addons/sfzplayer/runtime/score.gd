class_name SfzScore
extends RefCounted

# A song, in parts and intent, with no instrument named anywhere.
#
# The score is the layer a human (or Claude) writes. It says "the lead
# swells here, accented, slurred into the next note" - never "CC11 goes from
# 62 to 104 on channel 3". Which library hears that, and how, is the ensemble's
# business; how it is shaped into curves and timing is the performance
# compiler's. Keeping those three apart is what lets the same piece be
# re-voiced by swapping the ensemble underneath it and nothing else.
#
# Everything here is measured in BEATS, not seconds. Tempo lives in the
# song header and may change per section, so seconds only exist at the
# moment of playback.

const DYNAMICS := {
	"ppp": 16, "pp": 28, "p": 45, "mp": 62,
	"mf": 78, "f": 95, "ff": 110, "fff": 122,
}

# The two vibratos a lane can ask for, as a fraction of the ensemble's
# vibrato_depth control. Here rather than in the compiler because it is part
# of what a score is allowed to say, the same as DYNAMICS.
const VIBRATO := { "warm": 0.50, "deep": 0.85 }

# How strongly a lane is shaped phrase by phrase, as a multiplier on the
# arcs in the performance compiler. Here rather than in the compiler because
# it is part of what a score is allowed to say. `none` is not a lapse: an
# ostinato that is doing the job of a pedal wants to be a machine, and
# breathing it turns the floor of the piece into a waterbed.
const SHAPE := { "none": 0.0, "light": 0.5, "natural": 1.0, "broad": 1.6 }

# Where a lane sits against the beat, in seconds: ahead of it or behind it.
# Written as a name, or as a number of milliseconds (`pocket:-6`).
const POCKETS := { "push": -0.010, "on": 0.0, "lay": 0.014 }

const PITCH_CLASS := { "c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11 }

# How much of its written value a note actually sounds for. Anything short
# of 1.0 leaves the gap that makes a line articulate rather than smear.
const GATE_NORMAL := 0.92
const GATE_STACCATO := 0.45
# A muted note dies on its own, so it is let go late rather than cut.
const GATE_MUTED := 0.85
const GATE_TENUTO := 1.0
const GATE_SLUR := 1.02  # deliberate overlap, so legato mappings can fire

# The file's name without .score - "long-time-way" - which is what the
# loudness table (SfzLoudness) is keyed by. Empty for a score parsed from a
# string rather than a file.
var id: String = ""
var title: String = ""
var ensemble_id: String = ""
var tempo: float = 100.0
var beats_per_bar: int = 4
var beat_unit: int = 4
var key_root: int = 0     # pitch class, 0 = C
var key_mode: String = "minor"

# The parts the score's lanes name, from its `parts:` header, in declaration
# order: name -> {family, player}. `player` is the part whose performer plays
# it - itself for a player part, another part for a co-part (a lane of which
# shares that player's pocket, drift and limbs). A score with no header
# declares the six base families, each its own family and player.
var parts: Dictionary = {}
var sections: Dictionary = {}     # name -> SfzScore.Section
var section_order: Array[String] = []  # file order, before `order:` is applied
var order: Array[String] = []     # what actually plays, repeats expanded

# The part of `order` a game keeps playing until it is told to move on - a
# battle, a shop, a dungeon floor - written `order: intro [a b c] outro`.
# Indices into `order`, the first inclusive and the second exclusive; -1 for a
# piece that plays once through. See ScorePlayer for how it is played.
var loop_from: int = -1
var loop_to: int = -1


# One stretch of music. Every lane in it starts at beat 0 of the section.
class Section extends RefCounted:
	var name: String = ""
	var bars: int = 0
	var tempo: float = 0.0   # 0 = inherit from the song
	var repeat: int = 1
	var lanes: Dictionary = {}  # performance name -> SfzScore.Lane

	func beats(beats_per_bar: int) -> float:
		return float(bars * beats_per_bar)


# One line of a part within a section: the notes, plus the standing intent
# that colours all of them.
class Lane extends RefCounted:
	# The performance name, which is what the lane is keyed by in its section
	# and what its humanisation is seeded on: the head as written for a lane of
	# a player part (`lead`, `perc.feet`), and the player's name before it for a
	# lane of a co-part (`high` played by lead is `lead.high`). A migrated
	# score's lanes keep the names their voices had, so they keep their seeds.
	var name: String = ""
	var part: String = ""           # the declared part the lane plays
	var player: String = ""         # that part's player; the part itself if it has none
	var sub: String = ""            # "feet" for perc.feet; "" for a whole-part lane
	# The player's base family (SfzEnsemble.FAMILIES): what the performance
	# compiler's pocket and strum tables are read by.
	var base: String = ""
	var events: Array = []          # Array[SfzScore.Event], in time order

	# Standing intent. The performance compiler reads these; step 4's
	# literal player only honours `dyn` and `art`.
	var dyn_from: String = "mf"
	var dyn_to: String = ""         # non-empty means a ramp across the lane
	var art: String = ""            # articulation name, resolved by the ensemble
	var feel: String = "straight"   # straight | swing | loose | tight
	var vib: String = ""            # none | warm | deep
	var rot: String = ""            # slow | fast, for a rotary cabinet
	var shape: String = "natural"   # none | light | natural | broad
	var pocket: float = 0.0         # seconds; < 0 pushes, > 0 lays back
	var bend: Array = []            # [beats, cents] pairs: a pitch shape per note
	# The intensity levels the lane plays at, [lowest, highest], both
	# included; empty plays at every level. See SfzScorePlayer.set_intensity().
	var layer: Array = []

	func base_velocity() -> int:
		return SfzScore.DYNAMICS.get(dyn_from, 78)

	func perf_name() -> String:
		return name

	# Where the lane ends, in beats. Used to validate against the section.
	func length() -> float:
		if events.is_empty():
			return 0.0
		var last: Event = events[-1]
		return last.at + last.duration


# A note, chord, drum hit or rest, placed at `at` beats from the section
# start. `keys` is empty for a rest and for a drum; `drum` is empty for
# everything else.
class Event extends RefCounted:
	var at: float = 0.0
	var duration: float = 1.0
	var keys: Array[int] = []
	var drum: String = ""

	# Phrasing marks, straight off the note as written.
	var accent := false
	var soft := false
	var staccato := false
	var tenuto := false
	var slur := false    # tied into whatever follows
	var swell := false   # shape this note's own dynamic
	var muted := false   # damped at the string: the ensemble's mute samples
	var slide := false   # slides into whatever follows, on the same string
	var glide := false   # a slide whose join retunes after the onset, not
	                     # before it; always set alongside slide, because
	                     # every other part of the join is a slide's
	var scoop := false   # slides into this note from a few frets below
	var fall := false    # slides off the end of this note

	var line: int = 0    # for error messages, long after parsing

	func is_rest() -> bool:
		return keys.is_empty() and drum.is_empty()

	# Written duration times whatever the marks say. Slur wins over
	# staccato, because slurring a staccato note is a contradiction the
	# score should be allowed to contain without the player breaking.
	func sounding_duration() -> float:
		if slur or slide:
			return duration * SfzScore.GATE_SLUR
		if tenuto:
			return duration * SfzScore.GATE_TENUTO
		if staccato:
			return duration * SfzScore.GATE_STACCATO
		if muted:
			return duration * SfzScore.GATE_MUTED
		return duration * SfzScore.GATE_NORMAL

	func velocity(base: int) -> int:
		var v := base
		if accent:
			v += 18
		if soft:
			v -= 18
		return clampi(v, 1, 127)


# --- Pitch ---------------------------------------------------------------

# "d4" -> 62, "f#3" -> 54, "bb2" -> 46. C4 is 60, matching Godot and every
# SFZ library on the roster. Returns -1 if this is not a note name at all,
# which is how a drum lane's "kick" tells itself apart from a pitch.
static func parse_note(token: String) -> int:
	if token.is_empty():
		return -1
	var t := token.to_lower()
	var letter := t[0]
	if not PITCH_CLASS.has(letter):
		return -1
	var semitone: int = PITCH_CLASS[letter]
	var i := 1
	while i < t.length():
		var c := t[i]
		if c == "#" or c == "s":
			semitone += 1
		elif c == "b" or c == "f":
			semitone -= 1
		else:
			break
		i += 1
	var octave := 4
	if i < t.length():
		# Digits, with a minus for the octaves below 0. is_valid_int() alone
		# would also take "+4", which is no note name anyone writes.
		var rest := t.substr(i)
		var digits: String = rest.trim_prefix("-")
		if digits.is_empty() or digits.begins_with("+") or digits.begins_with("-") \
				or not digits.is_valid_int():
			return -1
		octave = rest.to_int()
		i = t.length()
	return (octave + 1) * 12 + semitone


# "d minor" - the header line read back, for logs and debug overlays.
func key_name() -> String:
	const NAMES := ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
	return "%s %s" % [NAMES[key_root % 12], key_mode]


static func note_name(key: int) -> String:
	const NAMES := ["c", "c#", "d", "d#", "e", "f", "f#", "g", "g#", "a", "a#", "b"]
	return "%s%d" % [NAMES[key % 12], key / 12 - 1]


# --- Timing --------------------------------------------------------------

func tempo_for(section: Section) -> float:
	return section.tempo if section.tempo > 0.0 else tempo


# Seconds each section in `order` starts at, and how long it runs. One pass
# so a tempo change in section 3 moves section 4 without anyone recomputing.
func timeline() -> Array:
	var out := []
	var cursor := 0.0
	for name in order:
		var section: Section = sections[name]
		var bpm := tempo_for(section)
		var length := section.beats(beats_per_bar) * 60.0 / bpm
		out.append({ "name": name, "at": cursor, "length": length, "bpm": bpm })
		cursor += length
	return out


func duration() -> float:
	var total := 0.0
	for entry in timeline():
		total += float(entry["length"])
	return total


func has_loop() -> bool:
	return loop_from >= 0 and loop_to > loop_from


# Seconds one pass of the loop lasts.
func loop_length() -> float:
	var total := 0.0
	var line := timeline()
	for i in range(loop_from, loop_to):
		total += float(line[i]["length"])
	return total


# Seconds from the top to where the first pass of the loop ends.
func loop_end() -> float:
	var entry: Dictionary = timeline()[loop_to - 1]
	return float(entry["at"]) + float(entry["length"])


# For a tool that rearranges `order`, after which the old indices mean nothing.
func clear_loop() -> void:
	loop_from = -1
	loop_to = -1
