class_name MusicTrackDatabase
extends RefCounted
## Every MusicTrack under res://data/music/*.tres — same flat-directory-
## scan shape as SpawnableUnitDatabase/DemonDatabase. Started as
## get_all()-only (for the debug music player to list), but MusicManager's
## own combat/negotiation hooks need to resolve a specific track by id
## too — find() mirrors DemonDatabase.find() exactly for that, same
## "index once, cache by id" idiom.
##
## Stateless from the outside — static, no instances, not an autoload —
## same reasoning as SpawnableUnitDatabase/DemonDatabase.

const TRACKS_DIR: String = "res://data/music/"

static var _all: Array[MusicTrack] = []
static var _by_id: Dictionary = {}


static func get_all() -> Array[MusicTrack]:
	if _all.is_empty():
		_load_all()
	return _all


## Null if no track with this id has ever been saved under TRACKS_DIR.
static func find(id: String) -> MusicTrack:
	if _all.is_empty():
		_load_all()
	return _by_id.get(id)


static func _load_all() -> void:
	for file_name in DirAccess.get_files_at(TRACKS_DIR):
		if not file_name.ends_with(".tres"):
			continue
		var track := load(TRACKS_DIR + file_name) as MusicTrack
		if track:
			_all.append(track)
			_by_id[track.id] = track
