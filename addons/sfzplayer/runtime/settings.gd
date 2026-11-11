class_name SfzSettings
extends RefCounted

# Where a game keeps its music, as project settings rather than constants, so
# the addon can be dropped into a project laid out any way at all.
#
#   sfzplayer/paths/samples      the folder ensemble "sfz" paths are relative to
#   sfzplayer/paths/ensembles    where an ensemble id is looked up: <ensembles>/<id>.json
#   sfzplayer/paths/registry     where a library's instruments are described:
#                                <registry>/<library>.json (docs/REGISTRY.md)
#   sfzplayer/paths/scores       where a score id is looked up: <scores>/<id>.score
#   sfzplayer/paths/transitions  the areas-and-rules table SfzMusicDirector reads
#   sfzplayer/paths/loudness     the per-score gains tools/loudness_fix.py
#                                writes (SfzLoudness reads it)
#   sfzplayer/audio/bus          the bus all the music ends up on, sending to
#                                Master: the one fader for a volume slider
#   sfzplayer/memory/preload_scale
#                                how much of each sample's head is held in
#                                memory, against what the ensembles ask for.
#                                0.5: with sfizz streaming a file only a window
#                                ahead of each voice, half the heads the
#                                ensembles were written for kept band's 156
#                                voices unstarved on a warm cache (2026-09-25;
#                                a cold cache or an HDD is not measured)
#   sfzplayer/memory/pinst_head_frames
#                                the head held of each .pinst note, in frames.
#                                A .pinst note is synthesized as it is read, so
#                                a head is audio made at load and kept. 0: no
#                                head at all - nothing of a note is unpacked
#                                or made at load, and each note is asked for
#                                as its event is scheduled, ahead of sounding
#                                (a note sent with no lead starts late, see
#                                stats().late). -1: the same head as any other
#                                sample file
#
# The editor plugin registers them with these defaults, so they show up in
# Project Settings; a project that never enables the plugin still gets the
# defaults. Each can be overridden per platform with a feature tag, the
# usual way - sfzplayer/memory/preload_scale.mobile = 0.5 - and the
# override is the value read.

const SAMPLES := "sfzplayer/paths/samples"
const ENSEMBLES := "sfzplayer/paths/ensembles"
const REGISTRY := "sfzplayer/paths/registry"
const SCORES := "sfzplayer/paths/scores"
const TRANSITIONS := "sfzplayer/paths/transitions"
const LOUDNESS := "sfzplayer/paths/loudness"
const BUS := "sfzplayer/audio/bus"
const PRELOAD_SCALE := "sfzplayer/memory/preload_scale"
const PINST_HEAD := "sfzplayer/memory/pinst_head_frames"

const DEFAULTS := {
	SAMPLES: "res://samples",
	ENSEMBLES: "res://ensembles",
	REGISTRY: "res://registry",
	SCORES: "res://scores",
	TRANSITIONS: "res://music/transitions.json",
	LOUDNESS: "res://scores/loudness.json",
	BUS: "Music",
	PRELOAD_SCALE: 0.5,
	PINST_HEAD: -1,
}

# sfizz's streaming has nothing to fall back on below this: a voice that
# reaches the end of what is loaded simply ends.
const MIN_PRELOAD := 1024


static func get_value(key: String) -> Variant:
	if not ProjectSettings.has_setting(key):
		return DEFAULTS[key]
	return ProjectSettings.get_setting_with_override(key)


static func get_path(key: String) -> String:
	return String(get_value(key))


static func _dir(key: String) -> String:
	var dir := get_path(key)
	return dir if dir.ends_with("/") else dir + "/"


# A path inside the samples folder, as an ensemble names it.
static func sample(relative: String) -> String:
	return samples_dir() + relative


# sfizz reads samples from disk itself, and in an exported game res:// is the
# .pck, which it cannot open. So a res:// samples folder is looked for beside
# the executable once exported - or, on macOS, in the bundle's Resources - and
# shipping one is copying the folder there. An absolute path or user:// is
# used as it is.
static func samples_dir() -> String:
	var dir := _dir(SAMPLES)
	if not dir.begins_with("res://") or not OS.has_feature("template"):
		return dir
	var base := OS.get_executable_path().get_base_dir()
	if OS.get_name() == "macOS":
		base = base.get_base_dir().path_join("Resources")
	return base.path_join(dir.trim_prefix("res://"))


static func ensemble_path(id: String) -> String:
	return "%s%s.json" % [_dir(ENSEMBLES), id]


static func registry_path(library: String) -> String:
	return "%s%s.json" % [_dir(REGISTRY), library]


static func score_path(id: String) -> String:
	return "%s%s.score" % [_dir(SCORES), id]


static func transitions_path() -> String:
	return get_path(TRANSITIONS)


static func loudness_path() -> String:
	return get_path(LOUDNESS)


static func music_bus() -> StringName:
	return StringName(get_path(BUS))


# Hands the .pinst head size to the engine; it holds for libraries loaded
# after the call.
static func apply_pinst_head() -> void:
	SfzInstrument.set_pinst_head_frames(int(get_value(PINST_HEAD)))


# The frames a layer actually preloads, for the frames its ensemble asks for.
static func preload_frames(asked: int) -> int:
	return maxi(MIN_PRELOAD, int(asked * float(get_value(PRELOAD_SCALE))))
