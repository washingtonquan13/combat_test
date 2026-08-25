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
##
## PREROLL, not pre-warming: an earlier version of this file just
## pre-created the loop AudioStreamPlayers during the intro (node +
## stream assigned early, play() still called at the transition). That
## measurably did NOT close the gap — instrumentation showed play()
## itself, not node creation or stream assignment, is where Godot pays
## real setup/decode cost (~80ms, measured), regardless of how long the
## player had already existed. So instead: the loop stems are actually
## played, silently (SILENT_VOLUME_DB), PREROLL_MARGIN before the intro
## is due to end — comfortably past that ~80ms — and "starting the
## loop" at the real transition moment is just raising their volume
## back to normal, never a fresh play() call. The tradeoff, worth
## knowing about: the loop is genuinely PREROLL_MARGIN seconds into its
## own content by the time it's revealed, not sample-0 — for a musical
## loop this is normally inaudible, but it's a real, deliberate
## approximation, not a perfect solution.
##
## REACTIVE, not estimated, for the exact reveal moment: earlier
## versions of this transition waited for the intro's playback
## position to reach a computed target (a wall-clock Timer, then later
## a hardware-clock-corrected position poll) — both hit the same real,
## confirmed bug. Per Godot's own AudioStreamPlayer docs,
## get_playback_position() "returns 0.0 if no sounds are playing," and
## since the intro stems are NOT loop-enabled, once one naturally
## finishes, its position resets to 0 rather than holding at the end.
## Polling for "position >= target" can race right past that reset and
## never see it again — confirmed as the cause of the intro simply
## going silent with the loop never starting. The reveal trigger now
## reacts to `not reference.playing` instead, which Godot itself flips
## the instant the stream genuinely stops — no estimate, no race to
## lose. The PREROLL trigger still has to fire proactively, before the
## end (there's no signal for "N seconds before finished"), so that
## part still uses an elapsed real-time estimate — the "System Clock
## Approach" from
## https://docs.godotengine.org/en/4.4/tutorials/audio/sync_with_audio.html,
## which the docs call fine for a wait this short (their drift warning
## is about continuously tracking a song over minutes, not a single
## ~18s proactive lead-in); being slightly off here only nudges the
## preroll window, it can never cause a hang the way the reveal side's
## old design could.

## A fade this long needs real time to actually reach silence — see
## NEAR_END_THRESHOLD just below for how that's kept from running past
## the loop's own boundary.
const QUICK_FADE_DURATION: float = 2.0
## Kept comfortably above QUICK_FADE_DURATION — not a fixed number of
## its own — so stop()'s two branches never overlap: any call landing
## in the quick-fade branch (time_remaining > this) is guaranteed to
## have the fade finish, and the player freed, before the loop's own
## boundary would have arrived. Without that guarantee, a long enough
## fade started just past this threshold would still be running when
## the loop wrapped to its next cycle — audible as the fade quietly
## "restarting" partway through instead of just dying out — and would
## eat into territory that should have gone to the outro instead. If
## QUICK_FADE_DURATION changes, this follows it automatically.
const NEAR_END_THRESHOLD: float = QUICK_FADE_DURATION + 0.3
const SILENT_VOLUME_DB: float = -80.0
## Comfortably above the ~80ms play()-latency measured via
## _log_first_audible — how long before a transition the NEXT phase is
## silently started, so that latency is already paid by the time it
## needs to be heard. Tune up if it's ever measured higher than this.
const PREROLL_MARGIN: float = 0.2

## Read-only outside this file — see get_phase(). Exists purely for
## observers (the debug music panel; nothing in this file's own control
## flow branches on it), so it's updated at whichever points make each
## transition obvious rather than derived from _active_players/
## _prerolled_players state, which would be a much fussier reverse-
## engineering of the same information.
enum Phase { STOPPED, INTRO, LOOP, OUTRO }

## Real gameplay triggers, not just the debug panel — CombatManager/
## NegotiationManager stay completely unaware this file exists (same
## decoupled, signal-driven shape as SystemLog/negotiation_panel.gd
## already use elsewhere), MusicManager just reacts. Track ids are
## content, not code — hardcoded here rather than exported/configurable,
## matching this project's general "if there's only ever one real
## answer, don't build a setting for it" stance; revisit if a second
## combat track or per-encounter music is ever wanted.
const COMBAT_TRACK_ID: String = "neon_pulse"
const NEGOTIATION_TRACK_ID: String = "negotiation"


func _ready() -> void:
	CombatManager.combat_started.connect(_on_combat_started)
	CombatManager.combat_ended.connect(_on_combat_ended)
	NegotiationManager.negotiation_started.connect(_on_negotiation_started)
	NegotiationManager.negotiation_ended.connect(_on_negotiation_ended)


func _on_combat_started(_turn_order: Array[Unit]) -> void:
	var track: MusicTrack = MusicTrackDatabase.find(COMBAT_TRACK_ID)
	if track:
		play_track(track)


## Stops outright rather than resuming some pre-combat track — this
## project has no ambient/exploration theme authored yet. Revisit once
## one exists.
func _on_combat_ended(_winning_faction: StringName) -> void:
	stop()


func _on_negotiation_started(_demon: Unit) -> void:
	var track: MusicTrack = MusicTrackDatabase.find(NEGOTIATION_TRACK_ID)
	if track:
		play_track(track)


## Guarded on CombatManager.in_combat specifically because negotiation
## ending doesn't always mean combat is still going — a RECRUIT/FLEE/
## HEAL_PLAYER outcome can remove the last hostile unit and end combat
## in the same beat negotiation itself ends. Without this check, a
## negotiation_ended arriving after combat_ended already silenced things
## would incorrectly restart the combat track right before it should
## have gone quiet. Whichever signal actually fires last, checking live
## state here (not signal-arrival order, which isn't worth depending on)
## keeps the result correct either way.
func _on_negotiation_ended(_outcome: int) -> void:
	if not CombatManager.in_combat:
		return
	var track: MusicTrack = MusicTrackDatabase.find(COMBAT_TRACK_ID)
	if track:
		play_track(track)


var _phase: Phase = Phase.STOPPED
var _current_track: MusicTrack = null
var _active_players: Dictionary = {}  # StringName -> AudioStreamPlayer
## Real (non-silent) volumes for whatever's currently prerolling, keyed
## the same way — so reveal knows what to raise each player BACK to,
## since preroll itself has to stomp volume_db down to silent.
var _prerolled_players: Dictionary = {}
var _prerolled_volumes: Dictionary = {}
## Bumped on every play_track()/stop() call. A pending await (waiting
## out an intro, or waiting for the loop's boundary) captures this
## value before waiting and checks it again after — if something newer
## came in during the wait, the resumed code silently abandons itself
## instead of acting on a now-stale request.
var _generation: int = 0


## Starts a new track. If something else is already playing, fades it
## out first (reuses _quick_fade_and_stop_active_players, the same
## tween stop()'s own quick-fade branch uses) and waits for that fade
## to finish in silence before the new track starts — a sequential
## handoff, not a true overlapping crossfade. That's deliberate: unlike
## a single track's own intro/loop/outro stems (authored to layer
## together on purpose), two different MusicTracks aren't composed to
## sound good played at once — different tempo, key, mood — so
## overlapping them would just be noise, not a blend. While the fade is
## running, get_phase()/get_current_track() report STOPPED/null rather
## than stale info about the outgoing track, which is no longer
## something a caller can act on anyway.
##
## Deliberately does NOT wait for the outgoing track's loop to reach
## its own boundary the way stop() can: switching to a different song
## is a "get there now" moment (entering combat, say), not a graceful
## ending, so there's no near-boundary/outro branch here, only the
## fade-then-switch.
func play_track(track: MusicTrack) -> void:
	if not track:
		return

	var token: int = _bump_generation()
	_hard_stop_prerolled_players()

	var was_playing: bool = not _active_players.is_empty()
	_quick_fade_and_stop_active_players()
	if was_playing:
		_phase = Phase.STOPPED
		_current_track = null
		await get_tree().create_timer(QUICK_FADE_DURATION).timeout
		if token != _generation:
			return

	_current_track = track

	if not track.intro.is_empty():
		_phase = Phase.INTRO
		_active_players = _spawn(track.intro)
		_play_all(_active_players)
		await _run_intro_to_loop(token, track)
	else:
		_phase = Phase.LOOP
		_active_players = _spawn_and_play(track.loop)


## Drives the intro->loop handoff: an elapsed-time estimate proactively
## triggers preroll before the intro ends, then reveal reacts to the
## intro's own `playing` state going false — see this file's header for
## why reveal specifically must not be estimated.
func _run_intro_to_loop(token: int, track: MusicTrack) -> void:
	var reference: AudioStreamPlayer = _active_players.values()[0]
	var intro_length: float = reference.stream.get_length()
	var start_usec: int = Time.get_ticks_usec()
	var latency_offset: float = AudioServer.get_time_to_next_mix() + AudioServer.get_output_latency()
	var preroll_started: bool = false

	while true:
		await get_tree().process_frame
		if token != _generation or not is_instance_valid(reference):
			return

		var elapsed: float = max((Time.get_ticks_usec() - start_usec) / 1000000.0 - latency_offset, 0.0)

		if not preroll_started and elapsed >= intro_length - PREROLL_MARGIN:
			preroll_started = true
			_start_preroll(track.loop)

		if not reference.playing:
			_hard_stop_active_players()
			_active_players = _reveal_prerolled()
			_phase = Phase.LOOP
			return


## Ends the current track. If the loop is already close to its own
## boundary, waits for it to actually get there (silent otherwise —
## nothing new starts until then) and transitions into the outro, same
## as a DJ letting a phrase finish before mixing out. Otherwise — the
## wait would be long enough to feel unresponsive — stops right where
## it is with a quick fade instead of cutting the outro in wherever the
## loop happened to be.
##
## That fade (_quick_fade_and_stop_active_players) is the same one
## play_track() reuses when switching to a different track — see that
## function's own comment for why the handoff there is a sequential
## fade-then-switch rather than a true overlapping crossfade.
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
			_phase = Phase.OUTRO
			# Bookkeeping only, for get_phase()'s benefit — the outro is a
			# one-shot, non-looping phase, so unlike the loop (see this
			# file's header for why THAT one never hooks `finished`),
			# there's no sync-drift risk in reacting to its natural end.
			var outro_reference: AudioStreamPlayer = _active_players.values()[0]
			outro_reference.finished.connect(_on_outro_finished.bind(token))
		else:
			_phase = Phase.STOPPED
	else:
		_quick_fade_and_stop_active_players()
		_phase = Phase.STOPPED

	_current_track = null


func _on_outro_finished(token: int) -> void:
	if token == _generation:
		_phase = Phase.STOPPED


func get_phase() -> Phase:
	return _phase


func get_current_track() -> MusicTrack:
	return _current_track


## 0.0 outside of Phase.LOOP/OUTRO's outro or whenever nothing valid is
## currently playing — see get_length()'s own note on why that's not
## distinguishable from "genuinely at position 0" without also checking
## get_phase(), which callers (the debug music panel) already do.
func get_position() -> float:
	if _active_players.is_empty():
		return 0.0
	var reference: AudioStreamPlayer = _active_players.values()[0]
	return reference.get_playback_position() if is_instance_valid(reference) else 0.0


## Repositions everything currently playing to the same point at once —
## same "back to back, nothing awaited in between" discipline _play_all
## uses, so a seek can't desync one stem from the rest. Debug-tool use
## only (the scrubber in the music panel); no guard against seeking
## right as an intro->loop preroll/reveal is about to fire — that
## transition's timing is wall-clock-driven (see this file's own header),
## not position-driven, so a seek landing in that narrow window could in
## principle skip a reveal with nothing prerolled yet. Acceptable for a
## manual debug scrub, not worth guarding against.
func seek(to_position: float) -> void:
	for player in _active_players.values():
		if is_instance_valid(player):
			player.seek(to_position)


func get_length() -> float:
	if _active_players.is_empty():
		return 0.0
	var reference: AudioStreamPlayer = _active_players.values()[0]
	if not is_instance_valid(reference) or not reference.stream:
		return 0.0
	return reference.stream.get_length()


func _bump_generation() -> int:
	_generation += 1
	return _generation


## Silently starts playing stems ahead of when they're actually needed
## — real play(), real position advancing, just inaudible — so whatever
## play()-time setup cost Godot pays happens now instead of at the
## moment this needs to sound clean. See _reveal_prerolled.
func _start_preroll(stems: Array[MusicStem]) -> void:
	_prerolled_players = _spawn(stems)
	_prerolled_volumes.clear()
	for stem in stems:
		if stem and stem.name in _prerolled_players:
			_prerolled_volumes[stem.name] = stem.volume_db
			_prerolled_players[stem.name].volume_db = SILENT_VOLUME_DB
	_play_all(_prerolled_players)


## Raises whatever's currently prerolling back to its real authored
## volume and hands it over as the new active set — no play() call
## here, which is the entire point: it's already genuinely playing.
func _reveal_prerolled() -> Dictionary:
	for stem_name in _prerolled_players:
		_prerolled_players[stem_name].volume_db = _prerolled_volumes.get(stem_name, 0.0)
	var revealed: Dictionary = _prerolled_players
	_prerolled_players = {}
	_prerolled_volumes.clear()
	return revealed


func _spawn(stems: Array[MusicStem]) -> Dictionary:
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
	return players


## Every player's play() call happens as close together as possible —
## whatever node/resource setup was needed already happened in _spawn,
## out of the way of this timing-sensitive part.
func _play_all(players: Dictionary) -> void:
	for player in players.values():
		player.play()


func _spawn_and_play(stems: Array[MusicStem]) -> Dictionary:
	var players: Dictionary = _spawn(stems)
	_play_all(players)
	return players


func _hard_stop_active_players() -> void:
	for player in _active_players.values():
		if is_instance_valid(player):
			player.queue_free()
	_active_players.clear()


func _hard_stop_prerolled_players() -> void:
	for player in _prerolled_players.values():
		if is_instance_valid(player):
			player.queue_free()
	_prerolled_players.clear()
	_prerolled_volumes.clear()


func _quick_fade_and_stop_active_players() -> void:
	for player in _active_players.values():
		if not is_instance_valid(player):
			continue
		var tween: Tween = create_tween()
		tween.tween_property(player, "volume_db", SILENT_VOLUME_DB, QUICK_FADE_DURATION)
		tween.tween_callback(player.queue_free)
	_active_players.clear()
