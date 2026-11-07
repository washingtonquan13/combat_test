class_name SfzLoudness
extends RefCounted

# How loud each score should be played, as data.
#
# Every piece in the game is mixed by ear against its own ensemble, and two
# pieces mixed that way can easily be 10 LU apart: the synth reference sat at
# -23 LUFS and Low End at -13.5. Heard one after the other that is a fader
# the player has to reach for, and at a crossfade between two areas it is a
# step you hear before you hear the music change. So each score gets one
# gain, measured rather than guessed: tools/loudness_fix.py renders every
# score through the offline renderer, measures it the way a broadcast meter
# would (ITU-R BS.1770, the LUFS scale) and writes the gain that brings it to
# the target into the file this reads -
#
#   {"target_lufs": -16.0, "scores": {"long-time-way": {"ensemble": "band",
#     "gain_db": -1.0, ...}, ...}}
#
# The gain is applied before the master chain, not after it, because the
# master chain's compressor and true-peak limiter are what make the level
# safe: a gain after them would move the peaks with it.
#
# It is keyed by the score's file name and says which ensemble it was measured
# with. Played with another ensemble the number means nothing, so it is 0 dB
# then - the piece at its written level - rather than the wrong trim.

# tools/loudness_fix.py MIN_GAIN and MAX_GAIN.
const MIN_GAIN_DB := -24.0
const MAX_GAIN_DB := 12.0

static var _table: Dictionary = {}
static var _loaded_path := ""
static var _loaded_time := -1


# The trim for `score` played with ensemble `ensemble_id`, in dB. 0 when there is no
# table, no entry, or the entry is for another ensemble.
static func gain_db(score: SfzScore, ensemble_id: String) -> float:
	if score == null or score.id == "":
		return 0.0
	var scores: Variant = table().get("scores", {})
	if not scores is Dictionary:
		return 0.0
	var entry: Variant = scores.get(score.id, {})
	if not entry is Dictionary or String(entry.get("ensemble", "")) != ensemble_id:
		return 0.0
	var gain: Variant = entry.get("gain_db", 0.0)
	if not (gain is float or gain is int) or not is_finite(float(gain)):
		return 0.0
	# The same bounds loudness_fix.py keeps to, so a hand-edited or damaged
	# file cannot turn a quiet piece up by 40 dB into the limiter.
	return clampf(float(gain), MIN_GAIN_DB, MAX_GAIN_DB)


# The whole file, read again whenever it changes on disk, so a game running
# in the editor picks up a new measurement without a restart.
static func table() -> Dictionary:
	var path := SfzSettings.loudness_path()
	if not FileAccess.file_exists(path):
		_table = {}
		_loaded_path = path
		_loaded_time = -1
		return _table
	var time := FileAccess.get_modified_time(path)
	if path == _loaded_path and time == _loaded_time:
		return _table
	_loaded_path = path
	_loaded_time = time
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary:
		_table = parsed
	else:
		push_error("SfzLoudness: %s is not a JSON object" % path)
		_table = {}
	return _table
