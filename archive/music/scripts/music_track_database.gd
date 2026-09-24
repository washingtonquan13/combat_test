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
##
## The scan-and-cache itself is ResourceCatalog (see that file's header
## for the full behaviour matrix); this file only supplies its directory,
## its id field, and the non-recursive/last-wins/no-dedupe shape that
## matches the original hand-written loader exactly.

const TRACKS_DIR: String = "res://data/music/"

static var _catalog: ResourceCatalog


static func get_all() -> Array[MusicTrack]:
	var result: Array[MusicTrack] = []
	for resource in _get_catalog().all():
		result.append(resource as MusicTrack)
	return result


## Null if no track with this id has ever been saved under TRACKS_DIR.
static func find(id: String) -> MusicTrack:
	return _get_catalog().find(id) as MusicTrack


## Forces a re-scan — same escape hatch SkillDatabase/DemonDatabase
## expose, for a dev/modding workflow that adds or edits a track .tres
## at runtime. Ordinary play never calls this.
static func refresh() -> void:
	_get_catalog().refresh()


static func _get_catalog() -> ResourceCatalog:
	if not _catalog:
		var extract_id := func(resource: Resource) -> Variant:
			var track := resource as MusicTrack
			return track.id if track else null
		_catalog = ResourceCatalog.new(TRACKS_DIR, false, extract_id, false, false, false)
	return _catalog
