class_name SfzMixer
extends RefCounted

# The room the ensemble is played in.
#
# Up to here every bus has gone straight to Master, dry, which is why the
# renders sounded like five instruments in five separate boxes rather than a
# band on a stage. Nothing about the samples was wrong; they simply had no
# space around them, and space is most of what "produced" means. A choir with
# no hall behind it is a choir sample. A kit with no room around it is a
# drum machine.
#
# So each of the six buses (SfzEnsemble.BUSES: lead guitar keys bass pad perc)
# gets its own reverb, its own high-pass and its own compressor, and every
# part of an ensemble is heard through one of them. Those buses feed whatever
# bus the Conductor was pointed at - Master in a test, MusicA/MusicB when the
# MusicDirector is crossfading two ensembles. The buses are therefore per
# destination:
#
#   Master_pad -> Master        (score_test, render)
#   MusicA_pad -> MusicA -> Master
#   MusicB_pad -> MusicB -> Master
#
# and that is exactly why this is code rather than the bus layout resource
# the engine would otherwise load. A saved layout is a fixed list of names;
# this needs five buses per destination, and the destinations are decided at
# runtime by whoever built the SfzMusicDirector. Eighteen hand-kept buses in a
# resource file is also not something anyone could review.
#
# The numbers below are the one place in the project where taste is written
# down as data. They are deliberately conservative: reverb wet stays under a
# third even on the pad, because a long hall on everything is the other way
# to sound cheap.

# Where the whole mix ends up is a bus of the music's own - "Music" unless
# the sfzplayer/audio/bus setting says otherwise - sending to Master. The
# master chain goes on it rather than on Master, so it treats the music and
# never the game's sound effects, and a game's music volume is one fader.
static func music_bus() -> StringName:
	return SfzSettings.music_bus()


# Two spaces, not six.
#
# Each bus used to have its own room - a 0.30 for the bass, 0.85 for the pad,
# something in between for everything else - and six rooms of six sizes is
# not a band in a place, it is six instruments each in their own box, which
# is exactly the sound this file was written to get away from. A mix engineer
# has one or two reverbs and *sends* each part to them by different amounts.
#
# The bus layout cannot do that directly - a Godot bus sends to one bus, and
# there is no aux send - but it does not need to. AudioEffectReverb is linear:
# two instances with the same room, damping and spread, fed different signals
# at different wet levels, sum to exactly what one shared instance would give
# with those signals sent to it at those levels. So every bus still carries
# its own reverb, but they are all the same reverb, and `wet` is the send.
#
# The two spaces are the usual pair. ROOM is the stage the band stands in:
# medium, fairly damped, so the kit and the guitars share early reflections
# without a tail smearing the eighths. HALL is for the parts that float over
# the band - the pad and the lead - bigger and brighter, the space a
# soundtrack's strings or a singing lead sit in.
const ROOM := {"room": 0.52, "damp": 0.50, "spread": 0.90}
const HALL := {"room": 0.80, "damp": 0.30, "spread": 1.00}

# Per bus: which space, how much of it is sent there (`wet`), and
# `predelay` in milliseconds, which is distance - a longer gap before the
# reflections is a part heard closer to the listener than to the walls.
# `hipass` is the cutoff of a separate high-pass filter in Hz, or 0 for none;
# `squash` is [threshold_db, ratio] for a compressor, or an empty array for
# none. The bus names are fixed, so the same numbers serve every ensemble.
const TREATMENTS := {
	# The tune. In the hall, but close: a long predelay keeps each note's
	# attack clear of its own reflections, so the line stays in front.
	"lead": {
		"space": HALL, "wet": 0.14, "predelay": 38.0,
		"hipass": 90.0, "squash": [-16.0, 3.0],
	},
	# The guitar comes with its own cabinet and microphone, so it needs
	# little room - only enough to stand on the same stage as the kit. The
	# high-pass is the working part: a distorted guitar and a bass fight
	# below about 110 Hz, and the bass wins by being written lower.
	"guitar": {
		"space": ROOM, "wet": 0.11, "predelay": 12.0,
		"hipass": 110.0, "squash": [-15.0, 3.5],
	},
	# A pluck's character is its attack, and reverb blurs exactly that, so
	# keys stay drier than the parts that sustain.
	"keys": {
		"space": ROOM, "wet": 0.12, "predelay": 14.0,
		"hipass": 80.0, "squash": [-14.0, 3.0],
	},
	# Nearly dry and forward: low frequencies in a reverb are what makes a
	# mix muddy, and the ear localises them poorly anyway.
	"bass": {
		"space": ROOM, "wet": 0.04, "predelay": 8.0,
		"hipass": 32.0, "squash": [-18.0, 4.0],
	},
	# The backdrop. The most hall of anything, with the long predelay so the
	# attack still arrives first.
	"pad": {
		"space": HALL, "wet": 0.30, "predelay": 42.0,
		"hipass": 60.0, "squash": [-12.0, 2.0],
	},
	# The kit is what tells the ear what room it is in, so it sends the most
	# of the band parts.
	"perc": {
		"space": ROOM, "wet": 0.17, "predelay": 10.0,
		"hipass": 0.0, "squash": [-18.0, 4.0],
	},
}

# Master: a gentle tilt, then glue, then a ceiling.
#
# The threshold is the part worth explaining, and it is also the part that
# was wrong for most of this file's life. It used to sit at -24 dB with 7 dB
# of makeup behind it, on the reasoning that the game mix peaked around
# -27 dBFS and a compressor set for a normal programme level would never
# open at all. That reading was real but its cause was not: four of the five
# buses were being attenuated by about 40 dB by a filter built with zero
# resonance, and a master compressor set to reach a broken mix compresses a
# working one by sixteen decibels on every bar. What that sounds like is
# exactly what it is - a band with no dynamics, which is most of what people
# mean by a mix sounding artificial.
#
# At -12 it was set for the level the mix runs at, and on the band it took
# about 1 dB off - a limiter for loud bars more than glue. Glue is 2-3 dB of
# gentle, slow compression working all the time, so that when one part plays
# harder the whole band leans back a little with it, which is what makes
# separately recorded parts sound as if they were played together. At -16 it
# takes 2.5-3 dB across the band's sections and closes the loudness spread
# between the quietest section and the loudest from 1.8 LU to 1.1; the
# makeup below puts the average back where it was.
const MASTER_EQ := [-3.0, 0.0, -1.0, 0.0, 1.0, 1.5]  # 32 100 320 1k 3.2k 10k
const MASTER_SQUASH := [-16.0, 2.0]

# The last thing on the music bus, in dBTP: true peak, the level of the wave
# a converter actually plays between the samples, not the samples themselves.
# It used to be Godot's AudioEffectLimiter at -0.8 dBFS with 2 dB of soft
# clip, which held every sample under -0.8 and still let Decadence out at
# +0.66 dBTP - over full scale - and whose soft clip bent everything above
# -2.8 dBFS whether it needed it or not. SfzTruePeakLimiter
# (native/src/true_peak.h) oversamples four times, looks 4 ms ahead and fades
# the gain down before a peak rather than bending the peak itself, and -1.0
# dBTP is the usual delivery ceiling: room for a lossy encoder's overshoot.
const MASTER_CEILING := -1.0
const MASTER_LOOKAHEAD_MS := 4.0
const MASTER_RELEASE_MS := 120.0

# The per-score level trim (SfzLoudness) is an Amplify with this name at the
# head of the Conductor's bus.
const TRIM_NAME := "sfz_trim"

# Makeup. A compressor with none is just an attenuator, so these put back
# what the ratios take out and no more - which is why the master's went up by
# two when its threshold came down by four at 2:1. "The limiter never
# engages" is how this used to read, and it was never measured. It does
# engage: with the ceiling lifted out of reach Sealed Ward peaks at +0.06
# dBTP, and holding that down costs 0.5% of the file more than half a
# decibel, 1.5 dB at worst, 0.03 LU overall. So it is a ceiling for the
# bar that goes wrong rather than part of the sound - which is what was
# meant, and now what is written.
const BUS_MAKEUP := 3.0
const MASTER_MAKEUP := 8.0

# The rest of the numbers both mixes need.
#
# Everything below appeared twice: once in _build_bus/_ensure_music as an
# effect property, and once in offline_bus/offline_master as a dictionary
# value for the C++ chain. Two copies of a number that must agree drift the
# moment somebody edits one half, and a comment asking the reader to check
# both halves is not a mechanism. They are named here so both halves read the
# same constant and the question cannot be asked again. The values are
# unchanged from the literals they replace.

# A high-pass with resonance 0.0 is a broken filter, not an unresonant one
# (see _build_bus); 0.5 is the engine's default and the working value.
const FILTER_RESONANCE := 0.5

# Bus compressor timing. Percussion gets the faster attack so a transient is
# caught rather than let through; everything else is slow enough to leave the
# attack alone and act on the body of the note.
const PERC_ATTACK_US := 12000.0
const BUS_ATTACK_US := 20000.0
const BUS_RELEASE_MS := 180.0

# Bus reverb, the parts that are the same for every bus: the tail's own
# high-pass keeps the bottom out of it, and `dry` is full because the reverb
# is a send, not an insert - `wet` per bus is the send amount.
const REVERB_HIPASS := 0.1
const REVERB_DRY := 1.0

# Master glue timing. Slower than a bus's, and the longer release is what
# makes it lean back with the band across a bar rather than per note. Named
# GLUE, not MASTER_*, because MASTER_RELEASE_MS above is already the true
# peak limiter's.
const MASTER_GLUE_ATTACK_US := 20000.0
const MASTER_GLUE_RELEASE_MS := 250.0

# Marks what we have already built, so a second ensemble load does not stack a
# second reverb on top of the first.
static var _built: Dictionary = {}


# The bus a given family of a Conductor on `destination` should play into.
static func bus_name(destination: StringName, family: String) -> StringName:
	return StringName("%s_%s" % [destination, family])


# Builds `destination` and its five family buses if they are not there yet,
# and the music bus's chain the first time anything asks. Safe to call per
# load. `destination` may be the music bus itself.
static func ensure(destination: StringName) -> void:
	var music := music_bus()
	_ensure_music(music)
	if destination != music:
		_ensure_bus(destination, music)
	for family in SfzEnsemble.BUSES:
		var bus := bus_name(destination, family)
		if _ensure_bus(bus, destination):
			_build_bus(bus, family)


# A bus's treatment with an ensemble's `buses` entry over it. An ensemble may
# move a bus to the other space and change how much of it is sent there and
# how far back it stands; the filter and the compressor are the bus's,
# whatever the ensemble. The reason it may: the treatments above are set for parts that bring
# their own air with them - sampled strings, a choir recorded in a church,
# a kit with its room mics - and an ensemble of parts generated by sfizz brings
# none. Next to a sampled choir, a synth kit at the band's send sounds as if
# it were in a different building.
static func treatment(family: String, ensemble_space: Dictionary = {}) -> Dictionary:
	var t: Dictionary = TREATMENTS[family].duplicate()
	if ensemble_space.has("space"):
		t.space = HALL if ensemble_space.space == "hall" else ROOM
	if ensemble_space.has("wet"):
		t.wet = float(ensemble_space.wet)
	if ensemble_space.has("predelay"):
		t.predelay = float(ensemble_space.predelay)
	return t


# Points the reverb on each of `destination`'s family buses at `ensemble`'s spaces
# (SfzEnsemble.buses, keyed by bus, which is to say by family).
# The buses outlive an ensemble - the next one loaded plays through the same ones
# - so this runs on every load and resets a bus the new ensemble says nothing
# about, rather than leaving it where the last ensemble put it.
static func apply_ensemble(destination: StringName, ensemble: SfzEnsemble) -> void:
	for family in SfzEnsemble.BUSES:
		var index := AudioServer.get_bus_index(bus_name(destination, family))
		if index < 0 or not TREATMENTS.has(family):
			continue
		var t := treatment(family, ensemble.buses.get(family, {}))
		for e in AudioServer.get_bus_effect_count(index):
			var verb := AudioServer.get_bus_effect(index, e) as AudioEffectReverb
			if verb == null:
				continue
			var space: Dictionary = t.space
			verb.room_size = space.room
			verb.damping = space.damp
			verb.spread = space.spread
			verb.predelay_msec = t.predelay
			verb.wet = t.wet


# Creates a bus sending to `send` if absent. Returns true if it made one,
# so the caller knows whether the effect chain still has to go on.
static func _ensure_bus(name: StringName, send: StringName) -> bool:
	if AudioServer.get_bus_index(name) >= 0:
		return false
	var index := AudioServer.bus_count
	AudioServer.add_bus(index)
	AudioServer.set_bus_name(index, name)
	AudioServer.set_bus_send(index, send)
	return true


static func _build_bus(bus: StringName, family: String) -> void:
	var index := AudioServer.get_bus_index(bus)
	if index < 0 or not TREATMENTS.has(family):
		return
	var t: Dictionary = treatment(family)

	# Order matters: clean up the bottom first, then compress what is left,
	# then put the result in a room. Reverb last means the tail is of the
	# compressed signal rather than being squashed itself, which is what
	# keeps a hall from breathing along with the kick.
	if float(t.hipass) > 0.0:
		var cut := AudioEffectHighPassFilter.new()
		cut.cutoff_hz = t.hipass
		# 0.5 is the engine's default, and it has to be said out loud:
		# resonance 0.0 does not mean an unresonant filter, it means a
		# broken one. Every family with a hipass was about 40 dB down
		# against perc, the one family that has none, until this read 0.5.
		cut.resonance = FILTER_RESONANCE
		AudioServer.add_bus_effect(index, cut)

	var squash: Array = t.squash
	if not squash.is_empty():
		var comp := AudioEffectCompressor.new()
		comp.threshold = squash[0]
		comp.ratio = squash[1]
		comp.attack_us = PERC_ATTACK_US if family == "perc" else BUS_ATTACK_US
		comp.release_ms = BUS_RELEASE_MS
		comp.gain = BUS_MAKEUP
		AudioServer.add_bus_effect(index, comp)

	var verb := AudioEffectReverb.new()
	var space: Dictionary = t.space
	verb.room_size = space.room
	verb.damping = space.damp
	verb.spread = space.spread
	verb.predelay_msec = t.predelay
	verb.hipass = REVERB_HIPASS
	verb.dry = REVERB_DRY
	verb.wet = t.wet
	AudioServer.add_bus_effect(index, verb)

	_built[bus] = true


static func _ensure_music(music: StringName) -> void:
	if _built.has(music):
		return
	_built[music] = true
	_ensure_bus(music, &"Master")
	# A game whose bus layout already has this bus with a chain of its own
	# keeps it, rather than getting a second one underneath.
	var index := AudioServer.get_bus_index(music)
	var has_chain := AudioServer.get_bus_effect_count(index) > 0
	# The trim goes in now, at 0 dB, while nothing is playing, rather than
	# when the first score starts. Adding an effect to a bus rebuilds every
	# effect instance on it, so one added mid-stream would reset the
	# limiter's lookahead and wipe whatever an AudioEffectRecord further
	# down had captured (render.gd's real-time take arms one before play).
	set_trim(music, 0.0)
	if has_chain:
		return

	var eq := AudioEffectEQ6.new()
	for band in MASTER_EQ.size():
		eq.set_band_gain_db(band, MASTER_EQ[band])
	AudioServer.add_bus_effect(index, eq)

	var glue := AudioEffectCompressor.new()
	glue.threshold = MASTER_SQUASH[0]
	glue.ratio = MASTER_SQUASH[1]
	glue.attack_us = MASTER_GLUE_ATTACK_US
	glue.release_ms = MASTER_GLUE_RELEASE_MS
	glue.gain = MASTER_MAKEUP
	AudioServer.add_bus_effect(index, glue)

	var ceiling := SfzTruePeakLimiter.new()
	ceiling.ceiling_db = MASTER_CEILING
	ceiling.lookahead_ms = MASTER_LOOKAHEAD_MS
	ceiling.release_ms = MASTER_RELEASE_MS
	AudioServer.add_bus_effect(index, ceiling)


# Sets the level trim at the head of `bus`, adding it the first time. Called
# by SfzScorePlayer with the score's SfzLoudness gain, so the music goes into
# the master chain at the level it was measured at. A trim of 0 still leaves
# the effect in place - it costs nothing - so the next score does not change
# the bus's layout while it plays.
static func set_trim(bus: StringName, db: float) -> void:
	var index := AudioServer.get_bus_index(bus)
	if index < 0:
		return
	var trim := trim_effect(bus)
	if trim == null:
		trim = AudioEffectAmplify.new()
		trim.resource_name = TRIM_NAME
		AudioServer.add_bus_effect(index, trim, 0)
	trim.volume_db = db


# The trim on `bus`, or null if it has none yet.
static func trim_effect(bus: StringName) -> AudioEffectAmplify:
	var index := AudioServer.get_bus_index(bus)
	if index < 0:
		return null
	for e in AudioServer.get_bus_effect_count(index):
		var effect := AudioServer.get_bus_effect(index, e) as AudioEffectAmplify
		if effect != null and effect.resource_name == TRIM_NAME:
			return effect
	return null


# --- The same chains, as data ---------------------------------------------

# The offline renderer builds the mix in C++ instead of as buses, and these
# two are how it is told what to build. They exist here, immediately under the
# functions above, for one reason: if the numbers lived in the renderer or in
# tools/render.gd then there would be two descriptions of the mix and the
# offline take would only agree with the live one until somebody edited the
# wrong file. Read each pair together - _build_bus with offline_bus,
# _ensure_music with offline_master - and any drift is visible on the page.
#
# Every number both halves share is now a constant above rather than a
# literal in each, so the common case - somebody changes a compressor's
# release and forgets the other half - cannot happen any more. What reading
# the pair together still catches is the other kind of drift: a value one
# half has and the other does not (rev_predelay_feedback is exactly that),
# or an effect added to one chain alone. That is why the pairing stands.

static func offline_bus(family: String, ensemble_space: Dictionary = {}) -> Dictionary:
	var t: Dictionary = treatment(family, ensemble_space)
	var space: Dictionary = t.space
	var squash: Array = t.squash
	return {
		"filter_cutoff": float(t.hipass),   # 0 means no filter, as above
		"filter_resonance": FILTER_RESONANCE,
		"comp_enabled": not squash.is_empty(),
		"comp_threshold": float(squash[0]) if not squash.is_empty() else 0.0,
		"comp_ratio": float(squash[1]) if not squash.is_empty() else 4.0,
		"comp_attack_us": PERC_ATTACK_US if family == "perc" else BUS_ATTACK_US,
		"comp_release_ms": BUS_RELEASE_MS,
		"comp_gain": BUS_MAKEUP,
		"rev_room": float(space.room),
		"rev_damp": float(space.damp),
		"rev_spread": float(space.spread),
		"rev_predelay": float(t.predelay),
		# Neither of these is set on the AudioEffectReverb above, so both are
		# its property defaults rather than a choice; they still have to be
		# said here, because the C++ side has no property list to fall back on.
		"rev_predelay_feedback": 0.4,
		"rev_hipass": REVERB_HIPASS,
		"rev_dry": REVERB_DRY,
		"rev_wet": float(t.wet),
	}


# `gain_db` is the amplify at the head of the chain: the score's loudness trim
# plus any extra gain a render asks for. Live those are two Amplify effects
# ahead of the EQ; offline they are one, since gains in series just add.
static func offline_master(gain_db: float) -> Dictionary:
	return {
		"amplify_db": gain_db,
		"eq": MASTER_EQ,
		"comp_threshold": float(MASTER_SQUASH[0]),
		"comp_ratio": float(MASTER_SQUASH[1]),
		"comp_attack_us": MASTER_GLUE_ATTACK_US,
		"comp_release_ms": MASTER_GLUE_RELEASE_MS,
		"comp_gain": MASTER_MAKEUP,
		"tp_ceiling_db": MASTER_CEILING,
		"tp_lookahead_ms": MASTER_LOOKAHEAD_MS,
		"tp_release_ms": MASTER_RELEASE_MS,
	}


# One line per bus, for a test to print. Reading it is the only way to see
# the layout, since there is no resource file to open in the editor.
static func describe() -> String:
	var lines: Array[String] = []
	for i in AudioServer.bus_count:
		var effects: Array[String] = []
		for e in AudioServer.get_bus_effect_count(i):
			effects.append(AudioServer.get_bus_effect(i, e).get_class()
					.replace("AudioEffect", ""))
		lines.append("  %-14s -> %-8s %s" % [
			AudioServer.get_bus_name(i), AudioServer.get_bus_send(i),
			", ".join(effects) if not effects.is_empty() else "(dry)"])
	return "\n".join(lines)
