class_name SfzEnsemble
extends RefCounted

# An ensemble is the translation layer between a score, which asks for parts
# ("lead", "high") and named controls ("brightness"), and a pile of
# third-party SFZ libraries that agree on none of that. Every library
# numbers its CCs differently, covers a different key range, and lays its
# drums out wherever its author felt like; the ensemble manifest and the
# instrument registry are where those differences are written down, so that
# nothing above this line has to know which library is loaded. Swap the ensemble
# and the same score plays.
#
# Two files make one ensemble (docs/REGISTRY.md). The registry,
# <registry>/<library>.json, holds the facts about a library's instruments -
# which CC the strings read as dynamics, where the bass keeps its switches -
# once, for every ensemble that uses them. The ensemble, <ensembles>/<id>.json,
# is one area's palette: which instruments play which part, how
# loud, on which bus, in which room. A score names parts; resolve() says which
# of the ensemble's parts plays each one.

# The six base families. They are the mixer's buses - every part is heard
# through one of them - and the base of every family, which is what the
# performance compiler's tables are keyed on.
const BUSES: Array[String] = ["lead", "guitar", "keys", "bass", "pad", "perc"]

# Family -> the base family it falls back to. A base family is its own. The
# fallback chooses a player's pocket and strum, and it is where resolve()
# looks for a family the ensemble has no part of (docs/REGISTRY.md §5).
const FAMILIES := {
	"lead": "lead", "guitar": "guitar", "keys": "keys",
	"bass": "bass", "pad": "pad", "perc": "perc",
	"brass": "guitar", "choir": "pad", "strings": "pad", "bells": "keys",
}

# Manifest sfz paths are relative to here, which keeps them readable and
# stops an ensemble from reaching outside the sample tree.

# Floats held in memory from the head of every sample, sfizz's own default.
# A part that streams (a big multisampled kit) lowers it; a part of short
# one-shots may as well keep whole files resident.
const DEFAULT_PRELOAD := 8192

# What a `gain_source` beside a `gain_db` is allowed to say.
#
#   measured  a tool reported a level for this part or layer and the number
#             follows from it
#   by-ear    somebody chose it by listening, or worked it out from a
#             measurement of something else and then confirmed it by ear
#   guessed   no evidence either way: the number is where it landed
#
# The default is `guessed`, which is the honest reading of a gain that says
# nothing about itself. Nothing in the engine reads this - it does not
# change a decibel - and that is the point: it is the provenance the mix
# tools could never recover, written down where the number lives.
const GAIN_SOURCES: Array[String] = ["measured", "by-ear", "guessed"]

# What each level of the two files may say (docs/REGISTRY.md §2.2). Anything
# else is refused at load rather than ignored: a field in the wrong place is a
# fact that would silently do nothing.
const LAYER_FIELDS: Array[String] = ["take", "delay", "release_cuts", "cabinet",
	"velocity", "transpose", "voices", "preload", "controls", "defaults", "keyswitches"]
const REGISTRY_LAYER_FIELDS: Array[String] = ["sfz", "name", "gain_db", "gain_source"]
const REGISTRY_INSTRUMENT_FIELDS: Array[String] = ["layers", "description", "range",
	"bend_range", "keyswitch_default", "drums"]
const ENTRY_FIELDS: Array[String] = ["instrument", "name", "gain_db", "gain_source"]
const PART_FIELDS: Array[String] = ["family", "bus", "layers", "gain_db", "gain_source",
	"voices", "preload", "range", "controls", "defaults", "keyswitches",
	"keyswitch_default", "bend_range", "drums"]
const SPACE_FIELDS: Array[String] = ["space", "wet", "predelay"]

var id: String
var name: String
var description: String
# Part name -> SfzEnsemble.Part, in manifest order: that order is the attach
# order within a bus and the "first part of a family" order of resolve().
var parts: Dictionary = {}
# Bus -> its space, any of "space" (room or hall), "wet" and "predelay", over
# the Mixer's treatment for that bus. A bus not named takes the Mixer's as it
# stands, which is what almost every ensemble should do. Per bus rather than per
# part because the reverb send is per bus: two parts on one bus cannot
# disagree about the room.
var buses: Dictionary = {}
# Family -> the part a score's part of that family plays when the ensemble has
# no part of its name (resolve(), step 2). Checked at load.
var family_parts: Dictionary = {}


# The base family of a family, "" for a name that is not a family.
static func base_family(family: String) -> String:
	return FAMILIES.get(family, "")


# One sampled timbre inside a part.
#
# A part is a line in the arrangement, not a patch, and General MIDI could
# never tell the two apart: program 40 was one fixed violin sound, and putting
# it on three channels gave the same waveform three times. That is thin and
# phasey rather than thick, and it is why a GM mock-up never sounds like a
# section. SFZ has no such limit, so a part here is a stack of independently
# recorded timbres - a second kit, a different pickup, a section behind a solo
# - each with its own window on velocity, its own offset in pitch and time,
# and its own trim.
#
# The rule that makes it work: no layer may be a copy of another. Two
# different performances of the same hit reinforce each other, because they
# disagree about everything except the pitch. Two copies of one performance
# add six decibels and a comb filter.
class Layer extends RefCounted:
	var name: String = ""
	# The registry instrument this layer is one of, `library/key`, for
	# tools/check.gd's reports and its --impact. Empty for a layer built by hand.
	var instrument: String = ""
	var sfz_path: String
	# What the take is hashed on besides the name: the SFZ as the ensemble names
	# it, spelled as if the samples folder were res://samples wherever it
	# really is. sfz_path is where the file is on this machine, and in an
	# exported game that is beside the executable, so hashing it would give
	# the export a different take from the editor and the offline render.
	# Empty for a layer built by hand, which hashes sfz_path.
	var take_key: String = ""
	var gain_db: float = 0.0
	# Where this number came from - see SfzEnsemble.GAIN_SOURCES. It changes
	# nothing about the sound; it is here so that the next person to balance
	# an ensemble knows which gains are worth re-measuring and which are already
	# somebody's decision. Empty when the layer names no gain at all.
	var gain_source: String = ""
	var transpose: int = 0         # semitones; +12 is an octave doubling
	var delay: float = 0.0         # seconds - a few ms reads as size, not as late
	var lovel: int = 0
	var hivel: int = 127
	var voices: int = 16
	var preload_frames: int = DEFAULT_PRELOAD
	var defaults: Dictionary = {}  # control -> 0..127, over the part's own
	# An impulse response to play the layer through - a speaker cabinet, for
	# an amp that stops at the power stage. Empty for none.
	var cabinet_path: String = ""
	# A layer that is its own take. A double-tracked guitar is two
	# performances of the part, not one performance copied, and the difference
	# between them is most of the sound: each note of the two lands a few
	# milliseconds apart by a different amount, one side picks harder than
	# the other, and the phase between them never settles. A fixed `delay`
	# alone is the studio's shortcut for that, and it sounds like one - a
	# single guitar through a short echo, with the same comb filter on every
	# note. `take_timing` is how far, in seconds, this take's timing wanders
	# from the written performance; `take_velocity` is how far its picking
	# strength does. Both zero means the layer plays the part exactly, as a
	# doubling does.
	var take_timing: float = 0.0
	var take_velocity: int = 0
	# Whether this SFZ's release samples cut off the notes still sounding:
	# a region with trigger=release sits in a group that a sustaining
	# region's off_by names. On such an instrument a note held into the next
	# one is not a longer note but a hole - its release fires after the new
	# press and silences it - so the compiler ends every note short of the
	# next onset (SfzPerformanceCompiler._hold). The engine cannot read this
	# back cheaply (metal-gtx is 14,000 regions), so the registry says it, as
	# it says bend_range.
	var release_cuts: bool = false
	# Keys this layer answers to, when they are not the part's. A stack of
	# one library's instruments shares the part's keys and leaves this empty;
	# a stack of several does not, because two libraries rarely put their
	# switches in the same place. The strings here are a case in point: the
	# violins switch at 48, the violas at 36 and the cellos at 84, and 48 is
	# a note the violas can play, so the part's keys alone would have every
	# articulation change sound a C on the violas. A layer that names any of
	# its own answers to none of the part's: an articulation it does not list
	# is one it cannot play, and it keeps the one it has rather than being
	# sent a key that means something else to it.
	var keyswitches: Dictionary = {}

	# The key this layer takes for `articulation`, or -1 for none. `fallback`
	# is the part's, which a layer with no keys of its own takes as written.
	func keyswitch(articulation: String, fallback: int) -> int:
		if keyswitches.is_empty():
			return fallback
		return int(keyswitches.get(articulation, -1))

	# Controls this layer answers to, when they are not the part's, for the
	# same reason as the keys above: one part can hold two families that read
	# the same CC opposite ways. Virtual Playing Orchestra's strings take the
	# mod wheel as "slower and quieter" - gain_cc1=-15, ampeg_attackcc1=0.5 -
	# while the synths beside them in the same part take it as "louder and
	# brighter". Sent one number, half the stack does the reverse of what the
	# score asked. Expression, CC11, is a plain gain sfizz applies to every
	# region, so the strings read it the way the score means it.
	var controls: Dictionary = {}     # control name -> CC number

	# The CC number this layer takes for `control`, or -1 for none. `fallback`
	# is the part's, which a layer naming no controls of its own takes whole;
	# a layer that names some overrides only those and keeps the rest.
	func cc(control: String, fallback: int) -> int:
		if not controls.has(control):
			return fallback
		return int(controls[control])
	# Seconds between the points of a take's slow wander.
	const TAKE_WANDER := 0.6

	# Velocity windows are how a stack changes timbre with force rather than
	# only volume: the shiny layer arrives when the player digs in, the way a
	# real instrument's own bright half does.
	func takes(velocity: int) -> bool:
		return velocity >= lovel and velocity <= hivel

	# Whether this layer is a take at all: a layer that is not plays the part
	# exactly, and its rows carry no take.
	func has_take() -> bool:
		return take_timing > 0.0 or take_velocity > 0

	# What this take's noise is fixed by: the layer, and the SFZ as the
	# ensemble names it. The "seed" of a timeline's take (native/src/
	# timeline.h, "Takes").
	func take_seed() -> int:
		return hash([name, take_key if take_key != "" else sfz_path])

	# Where this take's note at piece frame `frame` lands against the written
	# one, in frames at `rate`, and how much harder or softer it is picked.
	#
	# Most of a player's difference from their own previous take is slow -
	# they sit a little ahead through one phrase and a little behind through
	# the next - so three fifths of the reach is a wander that moves over
	# TAKE_WANDER, about a beat and a half at a rock tempo, and the rest is per
	# note on top. It is a function of the frame and nothing else, hashed
	# rather than drawn from a generator, so every key of a chord moves
	# together (one pick stroke), a note's offset does not depend on what was
	# scheduled before it, and a piece takes the same way on every run, live or
	# offline. Integer frames and a portable hash, so the timeline cursor
	# (native/src/timeline.h, "Takes") reads the same take to the frame: see
	# SfzEnsemble.take_frames().
	func take_frames(frame: int, rate: float) -> int:
		return SfzEnsemble.take_frames(take_seed(), take_timing, frame, rate)

	func take_velocity_at(frame: int, rate: float) -> int:
		return SfzEnsemble.take_velocity_at(take_seed(), take_velocity, frame, rate)

	# take_frames() in seconds, for a game's own note on the conductor's clock.
	func take_offset(at: float) -> float:
		var rate := AudioServer.get_mix_rate()
		return float(take_frames(roundi(at * rate), rate)) / rate

	func take_velocity_offset(at: float) -> int:
		var rate := AudioServer.get_mix_rate()
		return take_velocity_at(roundi(at * rate), rate)


# --- Takes ------------------------------------------------------------------
#
# A take's noise, on integer piece frames, exactly as native/src/timeline.h
# ("Takes") has it, so this file and the timeline cursor agree bit for bit.
# The one place it is written in GDScript: Layer.take_frames() and the score
# player's timelines both come here.

# splitmix64's constants, as signed 64-bit ints: a hex literal past 2^63 is
# not one GDScript can write.
const _MIX_1 := -4658895280553007687   # 0xBF58476D1CE4E5B9
const _MIX_2 := -7723592293110705685   # 0x94D049BB133111EB
const _CELL := -7046029254386353131    # 0x9E3779B97F4A7C15
const _STREAM := -3335678366873096957  # 0xD1B54A32D192ED03


# z >> n as uint64 would shift it: GDScript's >> keeps the sign.
static func _shr(z: int, n: int) -> int:
	return (z >> n) & ((1 << (64 - n)) - 1)


# splitmix64's finaliser. GDScript's int multiply wraps as uint64's does.
static func _mix(z: int) -> int:
	z = z ^ _shr(z, 30)
	z = z * _MIX_1
	z = z ^ _shr(z, 27)
	z = z * _MIX_2
	return z ^ _shr(z, 31)


# -1..1, fixed by the seed, the cell and the stream.
static func take_noise(seed_value: int, cell: int, stream: int) -> float:
	var h := _shr(_mix(seed_value + cell * _CELL + stream * _STREAM), 1)
	return float(h % 20001) / 10000.0 - 1.0


# `a` divided by `b` (> 0), rounded down, as C++'s floor of the quotient.
static func _floor_div(a: int, b: int) -> int:
	var q := a / b
	if a % b != 0 and a < 0:
		q -= 1
	return q


# A take's timing at piece frame `frame`, in frames: see Layer.take_frames().
static func take_frames(seed_value: int, timing: float, frame: int, rate: float) -> int:
	if timing <= 0.0:
		return 0
	var w := roundi(Layer.TAKE_WANDER * rate)
	var i := _floor_div(frame, w)
	var x := float(frame - i * w) / float(w)
	var a := take_noise(seed_value, i, 1)
	var b := take_noise(seed_value, i + 1, 1)
	var wander := a + (b - a) * (x * x * (3.0 - 2.0 * x))
	var pick := take_noise(seed_value, _floor_div(frame * 1000, roundi(rate)), 2)
	return roundi(timing * (0.6 * wander + 0.4 * pick) * rate)


# A take's velocity offset at piece frame `frame`.
static func take_velocity_at(seed_value: int, velocity: int, frame: int, rate: float) -> int:
	if velocity <= 0:
		return 0
	return roundi(float(velocity) * take_noise(seed_value, _floor_div(frame * 1000, roundi(rate)), 3))


# One part of the ensemble, with the lookups a player needs.
#
# A part is what a score's part plays on: its layers, and the settings that
# belong to the line rather than to any one instrument in it - where it is
# folded into range, which keys switch it, how far its wheel bends. Every
# layer of a part plays everything the part is given; there is no casting
# inside a part. A second line that wants other instruments is another part.
class Part extends RefCounted:
	var name: String
	# What it offers a score's part of that family (SfzEnsemble.resolve).
	var family: String
	# The mixer bus it plays through, one of BUSES: the string its players are
	# attached under offline and the bus they send to live.
	var bus: String
	var layers: Array = []            # SfzEnsemble.Layer, in manifest order
	var lokey: int = 0
	var hikey: int = 127
	var voices: int = 16
	var gain_db: float = 0.0
	# See SfzEnsemble.GAIN_SOURCES. Empty when the part names no gain at all.
	var gain_source: String = ""
	var preload_frames: int = DEFAULT_PRELOAD
	var controls: Dictionary = {}     # control name -> CC number
	# Cents the SFZ's pitch wheel reaches either way: its bend_up/bend_down,
	# which the engine cannot read back, so the ensemble says it when the file
	# changes sfizz's default of 200.
	var bend_range: float = 200.0
	var defaults: Dictionary = {}     # control name -> 0..127
	var drums: Dictionary = {}        # drum name -> key
	var keyswitches: Dictionary = {}  # articulation name -> key
	var keyswitch_default: String = ""

	# CC number for a named control, or -1 if this library has no such knob.
	# Callers are expected to shrug and carry on: a score that asks for
	# vibrato on a piano is not an error, it just has nothing to say to it.
	# The part's own map alone, which is where `bend` lives: whether a bend
	# goes to a control or the wheel is decided here, once for the part.
	func cc(control: String) -> int:
		return controls.get(control, -1)

	# Whether a "control" event for this part, once sent, reaches an
	# instrument. The one rule for that question: tools/check.gd's _heard(),
	# render.gd's --show tiers and --xref, and the compilers' has_control()
	# all call this and nothing else. It is SfzConductor.cc's walk, stated
	# without an instrument:
	#   bend  always - with no control of its own the conductor plays it on
	#         the SFZ's pitch wheel (conductor.gd, cc(), the `number < 0 and
	#         control == "bend"` branch), which every SFZ answers
	#   else  any layer's own CC for it, falling back on the part's
	# Counting bend as heard everywhere is the choice because it is what the
	# player does; a rule that disagreed with the conductor would be a second
	# opinion about the sound, not a measurement of it. A caller that has to
	# know a part reaches some layer at all asks that first: the compilers'
	# has_control() does, so a part with no layers is sent nothing, not even
	# a bend.
	#
	# `among` narrows the walk to some of the layers; left null it asks the
	# whole stack.
	func hears(control: String, among: Variant = null) -> bool:
		var number := cc(control)
		if control == "bend" and number < 0:
			return true
		var stack: Array = layers if among == null else among
		for layer in stack:
			if (layer as Layer).cc(control, number) >= 0:
				return true
		return false

	func key_for(drum: String) -> int:
		return drums.get(drum, -1)

	func keyswitch(articulation: String) -> int:
		return keyswitches.get(articulation, -1)

	# Whether an articulation change presses a key on any layer.
	# SfzConductor.articulate's walk, stated without an instrument: each layer
	# on its own keys or, with none, the part's. The compiler asks this before
	# it writes a keyswitch for a lane, and tools/check.gd before it calls one
	# lost, so a part of layers with no keys is neither sent one nor blamed
	# for missing it.
	func switches(articulation: String) -> bool:
		var fallback := keyswitch(articulation)
		for layer: Layer in layers:
			if layer.keyswitch(articulation, fallback) >= 0:
				return true
		return false

	# Whether any layer cuts off sounding notes with its release samples
	# (Layer.release_cuts).
	func cuts_on_release() -> bool:
		for layer: Layer in layers:
			if layer.release_cuts:
				return true
		return false

	# Folds a written pitch into the range this library actually samples.
	# Octaves, so the note keeps its pitch class and its place in the chord.
	func fit(key: int) -> int:
		while key < lokey:
			key += 12
		while key > hikey:
			key -= 12
		return clampi(key, lokey, hikey)

	func covers(key: int) -> bool:
		return key >= lokey and key <= hikey

	# The layer everything part-wide is addressed to: keyswitches, the clock
	# reference, anything that has to pick one. First in the manifest, which
	# is the one a reader would call the instrument.
	func primary() -> Layer:
		return layers[0]


# The part named `part_name`, or an empty one - no layers, so everything sent
# to it reaches nothing - for a name the ensemble does not have. The empty
# part is the answer a caller asking of every bus or every score part wants:
# an ensemble that leaves a part out is an ensemble where that part is silent.
func part(part_name: String) -> Part:
	if parts.has(part_name):
		return parts[part_name]
	var empty := Part.new()
	empty.name = part_name
	empty.family = part_name if FAMILIES.has(part_name) else ""
	empty.bus = base_family(empty.family)
	return empty


# Every part, in the order the conductor attaches them: bus by bus in BUSES
# order, and within a bus in manifest order. The offline renderer counts the
# voices attached under each bus string, and sfizz's seeds are drawn from that
# count, so this order is part of the sound (docs/REGISTRY.md §3.2).
func attach_order() -> Array:
	var out: Array = []
	for bus in BUSES:
		out.append_array(parts_on(bus))
	return out


# The parts that play through `bus`, in manifest order.
func parts_on(bus: String) -> Array:
	var out: Array = []
	for p: Part in parts.values():
		if p.bus == bus:
			out.append(p)
	return out


# Which of this ensemble's parts plays a score's part called `part_name`, of
# `family`. `player_part` is, for a co-part, the part its player resolved to;
# empty for a player. Returns {part, step}: the ensemble part's name ("" for
# none) and the step that found it (docs/REGISTRY.md §6):
#   1  exact name, whatever its family: an author who names a part like the
#      score's is casting it on purpose
#   2  the family's default part
#   3  a co-part's player's part: the same performer picking up their own
#      instrument is closer to the score than another section of the band
#   4  the family's fallback, tried as step 2 tries a family
#   5  nothing
func resolve(part_name: String, family: String, player_part: String = "") -> Dictionary:
	if parts.has(part_name):
		return {"part": part_name, "step": 1}
	var found := _family_part(family)
	if found != "":
		return {"part": found, "step": 2}
	if player_part != "":
		return {"part": player_part, "step": 3}
	var fallback := base_family(family)
	if fallback != "" and fallback != family:
		found = _family_part(fallback)
		if found != "":
			return {"part": found, "step": 4}
	return {"part": "", "step": 5}


# Step 2 of resolve() for `family`: the ensemble's family_parts entry, else
# the part named like the family if it is of that family, else the first part
# of the family in manifest order, else the first part of a family that falls
# back to it - an ensemble whose only pad-like part is a choir still has
# something for a score's pad.
func _family_part(family: String) -> String:
	if family == "":
		return ""
	if family_parts.has(family):
		return family_parts[family]
	if parts.has(family) and (parts[family] as Part).family == family:
		return family
	for p: Part in parts.values():
		if p.family == family:
			return p.name
	for p: Part in parts.values():
		if base_family(p.family) == family:
			return p.name
	return ""


# resolve() for every part a score declares: `score_parts` is SfzScore.parts,
# name -> {family, player}. Players first, since a co-part's step 3 is its
# player's answer. Returns name -> {part, step}, in the score's order.
func cast(score_parts: Dictionary) -> Dictionary:
	var found := {}
	# A player is its own player (SfzScore.parts writes it so); a missing
	# player reads the same way.
	for part_name in score_parts:
		var decl: Dictionary = score_parts[part_name]
		var player := String(decl.get("player", part_name))
		if player == "" or player == part_name:
			found[part_name] = resolve(part_name, decl.get("family", part_name))
	for part_name in score_parts:
		var decl: Dictionary = score_parts[part_name]
		var player := String(decl.get("player", part_name))
		if player != "" and player != part_name:
			var theirs: Dictionary = found.get(player, {"part": ""})
			found[part_name] = resolve(part_name, decl.get("family", part_name), theirs["part"])
	var ordered := {}
	for part_name in score_parts:
		ordered[part_name] = found[part_name]
	return ordered


# Reads an ensemble manifest and the registry files it names. Returns null and
# pushes an error if a file is missing or malformed, a field is in the wrong
# place, a name does not resolve, or a layer points at an SFZ that is not on
# disk - all of which are better caught here than as silence three seconds
# into a scene.
#
# `need_samples` false reads the manifests alone: a layer whose SFZ or cabinet
# is not on disk is kept rather than refused. The reading modes in
# tools/render.gd use it, because they never open an SFZ and a checkout
# without the sample tree should still be able to say what its ensembles map.
# Nothing that plays passes false.
static func load_from(path: String, need_samples: bool = true) -> SfzEnsemble:
	var data: Variant = _read_json(path, "Ensemble")
	if data == null:
		return null
	var text := FileAccess.get_file_as_string(path)

	var ensemble := SfzEnsemble.new()
	ensemble.id = data.get("id", path.get_file().get_basename())
	ensemble.name = data.get("name", ensemble.id)
	ensemble.description = data.get("description", "")
	var manifest := [path, text]

	# Format 2 is the only format. Anything else is refused whole rather
	# than read as far as it happens to match.
	if int(data.get("format", 0)) != 2:
		push_error("Ensemble %s: format %s is not supported; an ensemble is \"format\": 2 with a \"parts\" object (docs/REGISTRY.md)" % [
			path, str(data.get("format", 1))])
		return null
	var part_data: Variant = data.get("parts", {})
	if typeof(part_data) != TYPE_DICTIONARY or (part_data as Dictionary).is_empty():
		push_error("Ensemble %s: has no parts" % path)
		return null

	var buses: Variant = data.get("buses", {})
	if typeof(buses) != TYPE_DICTIONARY:
		push_error("Ensemble %s: \"buses\" is not an object" % path)
		return null
	for bus in buses:
		if not bus in BUSES:
			push_error("Ensemble %s: bus '%s' is unknown (%s)" % [
				_line_of(manifest, "buses", bus, ""), bus, ", ".join(BUSES)])
			return null
		var space: Dictionary = buses[bus]
		for key in space:
			if not key in SPACE_FIELDS:
				push_warning("Ensemble %s/%s: unknown space setting '%s'" % [ensemble.id, bus, key])
		if space.has("space") and not space.space in ["room", "hall"]:
			push_warning("Ensemble %s/%s: space should be room or hall, not '%s'" % [
				ensemble.id, bus, space.space])
		ensemble.buses[bus] = space

	# Registry files read so far this load, library -> its instruments; and the
	# instruments already warned about, so a warning is said once per load.
	var registry := {"files": {}, "warned": {}}
	var ensemble_preload := int(data.get("preload", DEFAULT_PRELOAD))
	for part_name in part_data:
		var part := _parse_part(ensemble.id, part_name, part_data[part_name], ensemble_preload,
			need_samples, manifest, registry)
		if part == null:
			return null
		ensemble.parts[part_name] = part

	var family_parts: Variant = data.get("family_parts", {})
	if typeof(family_parts) != TYPE_DICTIONARY:
		push_error("Ensemble %s: \"family_parts\" is not an object" % path)
		return null
	# Authoring data, so a wrong entry is refused rather than left to cast a
	# score's choir onto something that is not one.
	for family in family_parts:
		var named := String(family_parts[family])
		var where := _line_of(manifest, "family_parts", family, "")
		if not FAMILIES.has(family):
			push_error("Ensemble %s: family_parts names family '%s', which is not one (%s)" % [
				where, family, ", ".join(FAMILIES.keys())])
			return null
		if not ensemble.parts.has(named):
			push_error("Ensemble %s: family_parts sends %s to part '%s', which the ensemble does not have" % [
				where, family, named])
			return null
		var named_family := (ensemble.parts[named] as Part).family
		if named_family != family and base_family(named_family) != family:
			push_error("Ensemble %s: family_parts sends %s to part '%s', which is family %s, neither %s nor a family that falls back to it" % [
				where, family, named, named_family, family])
			return null
		ensemble.family_parts[family] = named
	return ensemble


# A JSON object from `path`, or null with an error pushed. `what` starts the
# message: "Ensemble" or "Registry".
static func _read_json(path: String, what: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_error("%s: no manifest at %s" % [what, path])
		return null
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		push_error("%s: %s line %d: %s" % [what, path, json.get_error_line(), json.get_error_message()])
		return null
	if typeof(json.data) != TYPE_DICTIONARY:
		push_error("%s: %s is not an object" % [what, path])
		return null
	return json.data


# `path:line` for the key `key` inside the object `section` ("parts",
# "buses"), or for the first `"needle"` written after it when one is given and
# found - so an error can be fixed where it is written. JSON does not keep
# lines, so this reads the text; the path alone is the answer when nothing
# matches.
static func _line_of(manifest: Array, section: String, key: String, needle: String) -> String:
	if manifest.size() != 2:
		return "?"
	var path: String = manifest[0]
	var text: String = manifest[1]
	var from := text.find("\"%s\"" % section)
	var at := text.find("\"%s\"" % key, maxi(from, 0))
	if at >= 0 and needle != "":
		var inside := text.find("\"%s\"" % needle, at)
		if inside >= 0:
			at = inside
	if at < 0:
		return path
	return "%s:%d" % [path, text.left(at).count("\n") + 1]


# The part `part_name` of the ensemble, as _line_of finds it.
static func _manifest_at(manifest: Array, part_name: String, needle: String) -> String:
	return _line_of(manifest, "parts", part_name, needle)


# A gain's provenance, defaulting to the honest answer for one that says
# nothing. A name outside GAIN_SOURCES is a typo worth hearing about, and is
# read as `guessed` rather than taken at its word.
static func _gain_source(ensemble_id: String, part_name: String,
		src: Dictionary) -> String:
	# No gain written means no gain to account for: the 0 dB a part or layer
	# gets by saying nothing is not a number anybody chose.
	if not src.has("gain_db"):
		return ""
	var source := String(src.get("gain_source", "guessed"))
	if source in GAIN_SOURCES:
		return source
	push_warning("Ensemble %s/%s: gain_source '%s' is not one of %s" % [
		ensemble_id, part_name, source, ", ".join(GAIN_SOURCES)])
	return "guessed"


# The instrument `instrument_id` ("library/key") from the registry, or null
# with an error pushed. Each library's file is read once per load; `registry`
# carries what has been read.
static func _instrument(instrument_id: String, registry: Dictionary, where: String) -> Variant:
	var split := instrument_id.split("/", true, 1)
	if split.size() != 2 or split[0] == "" or split[1] == "":
		push_error("Ensemble %s: instrument '%s' is not a registry id (library/key)" % [
			where, instrument_id])
		return null
	var library := split[0]
	var files: Dictionary = registry["files"]
	if not files.has(library):
		var read: Variant = _read_registry(library)
		if read == null:
			return null
		files[library] = read
	var instruments: Dictionary = files[library]
	if not instruments.has(split[1]):
		push_error("Ensemble %s: instrument '%s' is not in %s" % [
			where, instrument_id, SfzSettings.registry_path(library)])
		return null
	return instruments[split[1]]


# A library's registry file, checked: its instruments, key -> instrument, or
# null with an error pushed.
static func _read_registry(library: String) -> Variant:
	var path := SfzSettings.registry_path(library)
	var data: Variant = _read_json(path, "Registry")
	if data == null:
		return null
	var text := FileAccess.get_file_as_string(path)
	var instruments: Variant = data.get("instruments", null)
	if typeof(instruments) != TYPE_DICTIONARY:
		push_error("Registry: %s has no \"instruments\" object" % path)
		return null
	for key in data:
		if not key in ["library", "description", "instruments"]:
			push_error("Registry: %s: unknown field '%s'" % [path, key])
			return null
	if String(data.get("library", library)) != library:
		push_error("Registry: %s says it is library '%s'" % [path, data["library"]])
		return null
	# JSON keeps the last of two equal keys and says nothing, so a duplicate
	# is looked for in the text: among the keys of "instruments" itself, not
	# anywhere in the file, where an instrument called "controls" or "take"
	# would meet every other instrument's field of that name.
	var seen := {}
	for key in _keys_of(text, "instruments"):
		if seen.has(key):
			push_error("Registry: %s: instrument '%s/%s' is defined twice" % [path, library, key])
			return null
		seen[key] = true
	for key in instruments:
		var inst: Variant = instruments[key]
		var at := "%s (%s/%s)" % [path, library, key]
		if typeof(inst) != TYPE_DICTIONARY or typeof(inst.get("layers", null)) != TYPE_ARRAY \
				or (inst["layers"] as Array).is_empty():
			push_error("Registry: %s: an instrument needs a list of layers" % at)
			return null
		if not _fields_ok(inst, LAYER_FIELDS + REGISTRY_INSTRUMENT_FIELDS, at, "Registry"):
			return null
		if inst.has("range") and not _range_ok(inst["range"]):
			push_error("Registry: %s: range %s is not [lowest key, highest key]" % [
				at, JSON.stringify(inst["range"])])
			return null
		for layer in inst["layers"]:
			if typeof(layer) != TYPE_DICTIONARY or String(layer.get("sfz", "")) == "":
				push_error("Registry: %s: every layer needs an \"sfz\"" % at)
				return null
			if not _fields_ok(layer, LAYER_FIELDS + REGISTRY_LAYER_FIELDS, at, "Registry"):
				return null
			if not _no_bend(layer, at, "Registry"):
				return null
	return instruments


# The keys written directly inside the top-level object's `field` object, in
# the order they appear, repeats and all. A walk over the text that follows
# strings and nesting, since a word is a key of `field` only at its depth.
static func _keys_of(text: String, field: String) -> Array:
	var keys: Array = []
	var depth := 0
	var inside := -1        # the depth of `field`'s object, once in it
	var last_key := ""      # the last key read at the top level
	var i := 0
	while i < text.length():
		var c := text[i]
		if c == "\"":
			var j := i + 1
			while j < text.length() and text[j] != "\"":
				j += 2 if text[j] == "\\" else 1
			var word: Variant = JSON.parse_string(text.substr(i, j - i + 1))
			i = j + 1
			var k := i
			while k < text.length() and text[k] in " \t\r\n":
				k += 1
			if k < text.length() and text[k] == ":" and word is String:
				if depth == 1:
					last_key = word
				elif depth == inside:
					keys.append(word)
			continue
		if c == "{" or c == "[":
			depth += 1
			if c == "{" and depth == 2 and inside < 0 and last_key == field:
				inside = depth
		elif c == "}" or c == "]":
			if depth == inside:
				return keys
			depth -= 1
		i += 1
	return keys


# A key range as written: two keys, lowest first. Anything else is refused
# rather than read as the whole keyboard, since a range quietly ignored stops
# the range findings reporting the notes a library does not have.
static func _range_ok(value: Variant) -> bool:
	if typeof(value) != TYPE_ARRAY or (value as Array).size() != 2:
		return false
	for key in value:
		if not typeof(key) in [TYPE_INT, TYPE_FLOAT]:
			return false
	return float(value[0]) <= float(value[1])


# Whether every key of `src` is one of `allowed`; pushes the error if not.
static func _fields_ok(src: Dictionary, allowed: Array, where: String, what: String) -> bool:
	for key in src:
		if not key in allowed:
			push_error("%s %s: unknown field '%s' (%s)" % [what, where, key, ", ".join(allowed)])
			return false
	return true


# `bend` is the part's alone: whether bends go to a control or to the wheel is
# decided once, from the part's own map, and a layer's `bend` would be a
# number nothing reads. The registry instrument may say it, as the fact of its
# file, and the part takes it from there (_derive); a registry layer or an
# ensemble layer entry may not (docs/REGISTRY.md §2.2).
static func _no_bend(src: Dictionary, where: String, what: String) -> bool:
	var controls: Variant = src.get("controls", {})
	if typeof(controls) == TYPE_DICTIONARY and (controls as Dictionary).has("bend"):
		push_error("%s %s: 'bend' may only be mapped in a registry instrument's or an ensemble part's controls" % [what, where])
		return false
	return true


static func _parse_part(ensemble_id: String, part_name: String, src_v: Variant,
		ensemble_preload: int, need_samples: bool, manifest: Array, registry: Dictionary) -> Part:
	var where := _manifest_at(manifest, part_name, "")
	if typeof(src_v) != TYPE_DICTIONARY:
		push_error("Ensemble %s: part '%s' is not an object" % [where, part_name])
		return null
	var src: Dictionary = src_v
	if not _fields_ok(src, PART_FIELDS, "%s: part '%s'" % [where, part_name], "Ensemble"):
		return null
	var part := Part.new()
	part.name = part_name
	part.family = String(src.get("family", ""))
	if part.family == "":
		push_error("Ensemble %s: part '%s' has no family (%s)" % [
			where, part_name, ", ".join(FAMILIES.keys())])
		return null
	if not FAMILIES.has(part.family):
		push_error("Ensemble %s: part '%s' has family '%s', which is not one (%s)" % [
			where, part_name, part.family, ", ".join(FAMILIES.keys())])
		return null
	part.bus = String(src.get("bus", base_family(part.family)))
	if not part.bus in BUSES:
		push_error("Ensemble %s: part '%s' is on bus '%s', which is not one (%s)" % [
			_manifest_at(manifest, part_name, "bus"), part_name, part.bus, ", ".join(BUSES)])
		return null

	part.voices = int(src.get("voices", part.voices))
	part.gain_db = float(src.get("gain_db", 0.0))
	part.gain_source = _gain_source(ensemble_id, part_name, src)
	part.preload_frames = int(src.get("preload", ensemble_preload))
	part.controls = src.get("controls", {})
	part.defaults = src.get("defaults", {})
	part.keyswitches = src.get("keyswitches", {})

	# Each entry names an instrument; a multi-layer one expands to all of its
	# layers, in order, with the entry's overrides on each.
	var used: Array = []   # the registry instruments, each once, in order
	var spans: Array = []  # [lo, hi] each layer sounds on, in written keys
	var drum_maps: Array = []  # [instrument id, {drum: written key}] per layer
	for entry in src.get("layers", []):
		var at := _manifest_at(manifest, part_name, String(entry.get("instrument", "")) \
				if typeof(entry) == TYPE_DICTIONARY else "")
		if typeof(entry) != TYPE_DICTIONARY or String(entry.get("instrument", "")) == "":
			push_error("Ensemble %s: part '%s' has a layer entry with no \"instrument\"" % [at, part_name])
			return null
		if not _fields_ok(entry, LAYER_FIELDS + ENTRY_FIELDS, "%s: part '%s'" % [at, part_name], "Ensemble"):
			return null
		if not _no_bend(entry, "%s: part '%s'" % [at, part_name], "Ensemble"):
			return null
		var instrument_id := String(entry["instrument"])
		var inst: Variant = _instrument(instrument_id, registry, at)
		if inst == null:
			return null
		var reg_layers: Array = inst["layers"]
		if reg_layers.size() > 1 and entry.has("name"):
			push_error("Ensemble %s: part '%s' names a layer of %s, which has %d; a name would give them all the same one" % [
				at, part_name, instrument_id, reg_layers.size()])
			return null
		if not used.has(inst):
			used.append(inst)
		_warn_registry_gain(ensemble_id, instrument_id, reg_layers, registry)
		for reg_layer in reg_layers:
			var layer := _build_layer(ensemble_id, part, instrument_id, inst, reg_layer, entry,
				need_samples, at)
			if layer == null:
				return null
			part.layers.append(layer)
			# The keys this layer sounds on, as the part is written: a layer
			# transposed up an octave reaches its lowest sample from a key
			# twelve below it.
			if inst.has("range"):
				spans.append([int(inst["range"][0]) - layer.transpose,
					int(inst["range"][1]) - layer.transpose])
			# Its drums the same way: a drum the file sounds on key k is
			# written k less the layer's transpose.
			var written := {}
			var map: Dictionary = inst.get("drums", {})
			for drum in map:
				written[drum] = map[drum] - layer.transpose
			drum_maps.append([instrument_id, written])

	if not _derive(part, src, used, spans, drum_maps, where):
		return null

	# A default naming a control the library does not have is a typo in the
	# manifest, not a graceful degradation - say so while it is cheap to fix.
	var declared := part.defaults.keys()
	for layer in part.layers:
		declared.append_array(layer.defaults.keys())
	for control in declared:
		if part.controls.has(control):
			continue
		# A layer naming the control itself is mapping enough; the part need
		# not also name it.
		var mapped := false
		for layer in part.layers:
			if (layer as Layer).controls.has(control):
				mapped = true
				break
		if not mapped:
			push_warning("Ensemble %s/%s: default for unmapped control '%s'" % [
				ensemble_id, part_name, control])

	return part


# The registry holds facts, and a gain somebody chose by ear is a palette
# choice, which belongs in the ensemble. It still plays - provenance is not
# structure - so this is a warning, once per instrument.
static func _warn_registry_gain(ensemble_id: String, instrument_id: String, reg_layers: Array,
		registry: Dictionary) -> void:
	var warned: Dictionary = registry["warned"]
	if warned.has(instrument_id):
		return
	for reg_layer: Dictionary in reg_layers:
		if reg_layer.has("gain_db") and String(reg_layer.get("gain_source", "guessed")) != "measured":
			warned[instrument_id] = true
			push_warning("Ensemble %s: registry instrument %s has a gain that is not measured ('%s'); a chosen gain belongs in the ensemble" % [
				ensemble_id, instrument_id, reg_layer.get("gain_source", "guessed")])
			return


# The part-scoped settings a part does not write, from its instruments
# (docs/REGISTRY.md §2.3): the range as the union of the keys each layer sounds
# on, its instrument's range less its transpose; the drums as the union of
# their maps, each key less its layer's transpose the same way; and the bend
# control, bend_range and keyswitch_default as the value they agree on. A
# disagreement is refused, naming the part, which has to choose.
static func _derive(part: Part, src: Dictionary, used: Array, spans: Array, drum_maps: Array,
		where: String) -> bool:
	if src.has("range"):
		if not _range_ok(src["range"]):
			push_error("Ensemble %s: part '%s' has range %s, which is not [lowest key, highest key]" % [
				where, part.name, JSON.stringify(src["range"])])
			return false
		part.lokey = int(src["range"][0])
		part.hikey = int(src["range"][1])
	else:
		var lo := 128
		var hi := -1
		for span: Array in spans:
			lo = mini(lo, int(span[0]))
			hi = maxi(hi, int(span[1]))
		if hi >= 0:
			part.lokey = clampi(lo, 0, 127)
			part.hikey = clampi(hi, 0, 127)

	if src.has("drums"):
		part.drums = src["drums"]
	else:
		var drums := {}
		for pair: Array in drum_maps:
			var map: Dictionary = pair[1]
			for drum in map:
				if drums.has(drum) and int(drums[drum]) != int(map[drum]):
					push_error("Ensemble %s: part '%s' has layers that put drum '%s' on %d and %d (%s); write the part's own drums map" % [
						where, part.name, drum, int(drums[drum]), int(map[drum]), pair[0]])
					return false
				drums[drum] = map[drum]
		part.drums = drums

	# The bend control: the part's own, or the one its instruments' files
	# answer on. An instrument that does not say one bends on the wheel, and is
	# not a disagreement.
	if not part.controls.has("bend"):
		var bend: Variant = null
		for inst: Dictionary in used:
			var own: Dictionary = inst.get("controls", {})
			if not own.has("bend"):
				continue
			if bend != null and int(bend) != int(own["bend"]):
				push_error("Ensemble %s: part '%s' has instruments that bend on CC%d and CC%d; write the part's own bend control" % [
					where, part.name, int(bend), int(own["bend"])])
				return false
			bend = own["bend"]
		if bend != null:
			part.controls = part.controls.duplicate()
			part.controls["bend"] = bend

	for field in ["bend_range", "keyswitch_default"]:
		var value: Variant = src.get(field, null)
		if value == null:
			for inst: Dictionary in used:
				if not inst.has(field):
					continue
				if value != null and str(value) != str(inst[field]):
					push_error("Ensemble %s: part '%s' has instruments that disagree on %s (%s and %s); write the part's own" % [
						where, part.name, field, str(value), str(inst[field])])
					return false
				value = inst[field]
		if value == null:
			continue
		if field == "bend_range":
			part.bend_range = maxf(float(value), 1.0)
		else:
			part.keyswitch_default = String(value)
	return true


# The first of the ensemble's layer entry, the registry layer and the registry
# instrument that says `key`, or `fallback`.
static func _pick(key: String, entry: Dictionary, reg_layer: Dictionary, inst: Dictionary,
		fallback: Variant) -> Variant:
	for level in [entry, reg_layer, inst]:
		if level.has(key):
			return level[key]
	return fallback


# A map merged key by key, the nearest level that has a key winning it.
static func _merged(key: String, entry: Dictionary, reg_layer: Dictionary,
		inst: Dictionary) -> Dictionary:
	var out := {}
	for level in [inst, reg_layer, entry]:
		var map: Dictionary = level.get(key, {})
		for k in map:
			out[k] = map[k]
	return out


# One layer, from a registry layer and the ensemble entry that uses it.
# Layers take the part's voice count and preload unless they argue, because
# most of the time a doubling wants what the part wants and saying so twice is
# just somewhere else for the two to disagree.
static func _build_layer(ensemble_id: String, part: Part, instrument_id: String, inst: Dictionary,
		reg_layer: Dictionary, entry: Dictionary, need_samples: bool, where: String) -> Layer:
	var layer := Layer.new()
	var sfz := String(reg_layer["sfz"])
	layer.instrument = instrument_id
	layer.sfz_path = SfzSettings.sample(sfz)
	# The default folder, spelled out, so every take already heard is unchanged.
	layer.take_key = "res://samples/" + sfz
	layer.name = String(entry.get("name", reg_layer.get("name",
		layer.sfz_path.get_file().get_basename())))

	if need_samples and not FileAccess.file_exists(layer.sfz_path):
		push_error("Ensemble %s: part '%s' (%s) has no SFZ at %s (run tools/fetch_samples.sh)" % [
			where, part.name, instrument_id, layer.sfz_path])
		return null

	# Gain adds up, the part's and the layer's, and the layer's is the entry's
	# or else the registry's: a registry gain is a measurement of the file,
	# which an ensemble may overrule.
	var gain_from: Dictionary = entry if entry.has("gain_db") else reg_layer
	layer.gain_db = float(gain_from.get("gain_db", 0.0))
	layer.gain_source = _gain_source(ensemble_id, part.name, gain_from)
	layer.transpose = int(_pick("transpose", entry, reg_layer, inst, 0))
	layer.delay = float(_pick("delay", entry, reg_layer, inst, 0.0))
	layer.voices = int(_pick("voices", entry, reg_layer, inst, part.voices))
	layer.preload_frames = int(_pick("preload", entry, reg_layer, inst, part.preload_frames))
	layer.release_cuts = bool(_pick("release_cuts", entry, reg_layer, inst, false))
	layer.controls = _merged("controls", entry, reg_layer, inst)
	# An instrument's bend is the part's (_derive), not a layer control.
	layer.controls.erase("bend")
	layer.defaults = _merged("defaults", entry, reg_layer, inst)
	# Whole, not merged: a layer that names one key answers to none of the
	# part's, and a map built from two levels would be neither's.
	for level in [entry, reg_layer, inst]:
		var keys: Dictionary = level.get("keyswitches", {})
		if not keys.is_empty():
			layer.keyswitches = keys
			break
	var take: Dictionary = _pick("take", entry, reg_layer, inst, {})
	layer.take_timing = float(take.get("timing", 0.0))
	layer.take_velocity = int(take.get("velocity", 0))
	var cabinet: Variant = _pick("cabinet", entry, reg_layer, inst, null)
	if cabinet != null:
		layer.cabinet_path = SfzSettings.sample(String(cabinet))
		if need_samples and not FileAccess.file_exists(layer.cabinet_path):
			push_error("Ensemble %s/%s: no cabinet at %s" % [
				ensemble_id, part.name, layer.cabinet_path])
			return null

	var window: Array = _pick("velocity", entry, reg_layer, inst, [])
	if window.size() == 2:
		layer.lovel = clampi(int(window[0]), 0, 127)
		layer.hivel = clampi(int(window[1]), 0, 127)

	return layer
