class_name MusicTrackDatabase
extends RefCounted
## Every MusicTrack under res://data/music/*.tres, for the debug music
## player (see debug_music_panel.gd) to list and play — same flat-
## directory-scan shape as SpawnableUnitDatabase, for the same reason:
## nothing here needs single-id lookup, only "all of them" for a list.
##
## Stateless from the outside — static, no instances, not an autoload —
## same reasoning as SpawnableUnitDatabase/DemonDatabase.

const TRACKS_DIR: String = "res://data/music/"

static var _all: Array[MusicTrack] = []


static func get_all() -> Array[MusicTrack]:
	if _all.is_empty():
		_load_all()
	return _all


static func _load_all() -> void:
	for file_name in DirAccess.get_files_at(TRACKS_DIR):
		if not file_name.ends_with(".tres"):
			continue
		var track := load(TRACKS_DIR + file_name) as MusicTrack
		if track:
			_all.append(track)
