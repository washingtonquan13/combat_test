extends Node
## Autoload singleton. Register as "MusicManager" under
## Project > Project Settings > AutoLoad.
##
## Plays a MusicTrack's intro (once) then loop (repeating, natively —
## see below) — call stop() to end it, which either waits for the loop
## to reach its own boundary and plays the outro, or, if that wait would
## be too long, fades out immediately instead. See stop()'s own comment
## for the exact rule; it's the one piece of this file worth reading
## closely before changing.
##
## Every stem in a phase is spawned as its own AudioStreamPlayer (not
## AudioStreamPlayer3D — music isn't positional, unlike SfxLayer's SFX
## use case this is otherwise modeled on) and started in the same
## function, back to back with nothing awaited in between, which is
## what keeps them phase-locked — Godot's audio server buffers same-
## frame play() calls closely enough for this to hold up as music, not
## just approximately-together sound effects.
##
## The loop phase is expected to be imported with native loop points
## set (WAV import > Loop Mode > Forward) — this file never re-triggers
## a loop stem itself. That's deliberate: re-triggering on the
## `finished` signal would reintroduce exactly the sync-drift risk
## simultaneous playback avoids in the first place (nothing guarantees
## every stem's `finished` fires on the identical sample), and native
## looping is sample-accurate and gapless for free.
##
## _active_players is keyed by MusicStem.name rather than being a bare
## list — costs nothing for the fixed-song version this pass builds,
## but it's the exact lookup a future dynamic-layering feature needs to
## address "the drums layer" by name instead of by array position.

const NEAR_END_THRESHOLD: float = 2.0
const QUICK_FADE_DURATION: float = 0.4
const SILENT_VOLUME_DB: float = -80.0

var _current_track: MusicTrack = null
var _active_players: Dictionary = {}  # StringName -> AudioStreamPlayer
## Bumped on every play_track()/stop() call. A pending await (waiting
## out an intro, or waiting for the loop's boundary) captures this
## value before waiting and checks it again after — if something newer
## came in during the wait, the resumed code silently abandons itself
## instead of acting on a now-stale request.
var _generation: int = 0


func play_track(track: MusicTrack) -> void:
	if not track:
		return

	var token: int = _bump_generation()
	_hard_stop_active_players()
	_current_track = track

	if not track.intro.is_empty():
		_active_players = _spawn_and_play(track.intro)
		var intro_length: float = track.intro[0].stream.get_length()
		await get_tree().create_timer(intro_length).timeout
		if token != _generation:
			return
		_hard_stop_active_players()

	_active_players = _spawn_and_play(track.loop)


## Ends the current track. If the loop is already close to its own
## boundary, waits for it to actually get there (silent otherwise —
## nothing new starts until then) and transitions into the outro, same
## as a DJ letting a phrase finish before mixing out. Otherwise — the
## wait would be long enough to feel unresponsive — stops right where
## it is with a quick fade instead of cutting the outro in wherever the
## loop happened to be. Once real crossfading exists, that second case
## is where it plugs in: fade the loop out as it currently sounds,
## rather than a hard stop dressed up with a fade.
func stop() -> void:
	if _active_players.is_empty():
		return

	var token: int = _bump_generation()
	var reference: AudioStreamPlayer = _active_players.values()[0]
	var time_remaining: float = reference.stream.get_length() - reference.get_playback_position()

	if time_remaining <= NEAR_END_THRESHOLD:
		await get_tree().create_timer(time_remaining).timeout
		if token != _generation:
			return
		_hard_stop_active_players()
		if _current_track and not _current_track.outro.is_empty():
			_active_players = _spawn_and_play(_current_track.outro)
	else:
		_quick_fade_and_stop_active_players()

	_current_track = null


func _bump_generation() -> int:
	_generation += 1
	return _generation


func _spawn_and_play(stems: Array[MusicStem]) -> Dictionary:
	var players: Dictionary = {}
	for stem in stems:
		if not stem or not stem.stream:
			continue
		var player := AudioStreamPlayer.new()
		add_child(player)
		player.bus = &"Music"
		player.stream = stem.stream
		player.volume_db = stem.volume_db
		players[stem.name] = player

	# Separate loop from spawn so every player's play() call happens as
	# close together as possible — building the array above does the
	# (comparatively slow) node/resource setup work first, out of the
	# way of the timing-sensitive part.
	for player in players.values():
		player.play()

	return players


func _hard_stop_active_players() -> void:
	for player in _active_players.values():
		if is_instance_valid(player):
			player.queue_free()
	_active_players.clear()


func _quick_fade_and_stop_active_players() -> void:
	for player in _active_players.values():
		if not is_instance_valid(player):
			continue
		var tween: Tween = create_tween()
		tween.tween_property(player, "volume_db", SILENT_VOLUME_DB, QUICK_FADE_DURATION)
		tween.tween_callback(player.queue_free)
	_active_players.clear()
