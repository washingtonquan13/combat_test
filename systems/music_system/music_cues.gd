class_name MusicCues
extends RefCounted
## What plays when the story says so, as data: music/cues.json.
##
## An area's music for a moment is "<area id>.<moment>" (see
## MusicManager.music_area()). A cue plays something else in its place while
## the story is at a point that calls for it - the valley's fights while the
## goblins are raiding it, and its ordinary fights again once they are beaten.
## Not a unit's music, and not a place's: the same goblins in the same camp
## play the area's music before the raid and after it.
##
##   "cues": [
##     { "area": "goblin_quarry", "moment": "combat",
##       "when": ["goblin_raid.begun", "!goblin_raid.broken"],
##       "music": "warband_battle" }
##   ]
##
## `area` is an area id or "*"; `moment` is exploration, combat or
## negotiation; `when` is FlagManager flags that must all be set, "!" for one
## that must not be; `music` is a name in music/transitions.json. The first cue
## that holds wins, so a more particular cue goes above a general one.
##
## Flags rather than a cue's own on/off: the story already keeps its state
## there (a quest's stage is its flags), it saves with everything else, and a
## point in the story is a flag set once and never taken back - "begun and not
## broken" - so what happened stays on record.

const PATH := "res://music/cues.json"

var cues: Array[Dictionary] = []


static func load_from(path: String = PATH) -> MusicCues:
	var out := MusicCues.new()
	if not FileAccess.file_exists(path):
		return out
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not data is Dictionary:
		push_error("MusicCues: %s is not a JSON object" % path)
		return out
	for cue: Variant in data.get("cues", []):
		if not cue is Dictionary or not cue.has("area") or not cue.has("moment") \
				or not cue.has("music"):
			push_error("MusicCues: a cue needs an area, a moment and music: %s" % cue)
			continue
		out.cues.append(cue)
	return out


## The music the first cue that holds plays here at this moment, or "".
## `is_set` answers whether a flag is set (FlagManager.has_flag in the game).
func music_for(area_id: StringName, moment: StringName, is_set: Callable) -> String:
	for cue in cues:
		var area: String = cue["area"]
		if (area != "*" and area != String(area_id)) or cue["moment"] != String(moment):
			continue
		if holds(cue, is_set):
			return cue["music"]
	return ""


static func holds(cue: Dictionary, is_set: Callable) -> bool:
	for condition: String in cue.get("when", []):
		var wanted := not condition.begins_with("!")
		if bool(is_set.call(condition.trim_prefix("!"))) != wanted:
			return false
	return true


## Every flag any cue reads, so a change to one of them - and only those -
## sends the music to look again.
func flags_read() -> Dictionary[String, bool]:
	var out: Dictionary[String, bool] = {}
	for cue in cues:
		for condition: String in cue.get("when", []):
			out[condition.trim_prefix("!")] = true
	return out
