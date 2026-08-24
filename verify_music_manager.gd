extends Node

func _ready() -> void:
	var track: MusicTrack = load("res://data/music/level_up_groovy.tres")
	assert(track.id == "level_up_groovy", "track id got %s" % track.id)
	assert(track.intro.size() == 3 and track.loop.size() == 3 and track.outro.size() == 3, "expected 3+3+3 stems")
	var intro_names: Array = track.intro.map(func(s): return s.name)
	assert(&"bass" in intro_names and &"drums" in intro_names and &"synth" in intro_names, "intro stem names got %s" % [intro_names])
	print("1. MusicTrack data shape: OK")

	# 2. play_track spawns the intro correctly: right bus, right streams.
	MusicManager.play_track(track)
	await get_tree().process_frame
	await get_tree().process_frame

	assert(MusicManager._active_players.size() == 3, "expected 3 intro players, got %d" % MusicManager._active_players.size())
	for stem_name in MusicManager._active_players:
		var player: AudioStreamPlayer = MusicManager._active_players[stem_name]
		assert(player.bus == "Music", "player bus got %s" % player.bus)
		assert(player.playing, "intro player %s should be playing" % stem_name)
	var intro_bass_stem: MusicStem = track.intro.filter(func(s): return s.name == &"bass")[0]
	var bass_player: AudioStreamPlayer = MusicManager._active_players[&"bass"]
	assert(bass_player.stream == intro_bass_stem.stream, "intro bass player stream mismatch")
	print("2. Intro spawn: 3 players, correct bus, playing: OK")

	# 3. Intro -> loop transition, timed off the real intro length.
	var intro_length: float = track.intro[0].stream.get_length()
	await get_tree().create_timer(intro_length + 0.3).timeout

	assert(MusicManager._active_players.size() == 3, "expected 3 loop players after transition, got %d" % MusicManager._active_players.size())
	var loop_bass_stem: MusicStem = track.loop.filter(func(s): return s.name == &"bass")[0]
	var loop_bass_player: AudioStreamPlayer = MusicManager._active_players[&"bass"]
	assert(loop_bass_player.stream == loop_bass_stem.stream, "loop bass player stream mismatch")
	assert(loop_bass_player.stream != intro_bass_stem.stream, "loop stream should differ from intro stream")
	assert(loop_bass_player.playing, "loop player should be playing")
	print("3. Intro-to-loop transition (timed off real intro length): OK")

	# 4. stop() far from the loop boundary -> quick fade, no outro.
	var loop_length: float = track.loop[0].stream.get_length()
	print("loop_length=%f (informational)" % loop_length)
	MusicManager.stop()
	await get_tree().create_timer(MusicManager.QUICK_FADE_DURATION + 0.3).timeout

	assert(MusicManager._active_players.is_empty(), "expected silence after quick-fade stop, got %d active" % MusicManager._active_players.size())
	print("4. stop() far from boundary -> quick fade to silence, no outro: OK")

	# 5. stop() near the loop boundary -> waits, then plays outro.
	MusicManager.play_track(track)
	await get_tree().create_timer(intro_length + 0.3).timeout  # clear intro, into loop

	# Let the loop run until it's within the near-end window, then stop.
	var reference: AudioStreamPlayer = MusicManager._active_players.values()[0]
	var time_to_near_end: float = loop_length - reference.get_playback_position() - (MusicManager.NEAR_END_THRESHOLD - 0.5)
	if time_to_near_end > 0.0:
		await get_tree().create_timer(time_to_near_end).timeout
	MusicManager.stop()
	# Now within the threshold window — wait past however long stop()
	# itself decides to wait, plus a buffer for the outro to actually start.
	await get_tree().create_timer(MusicManager.NEAR_END_THRESHOLD + 0.5).timeout

	assert(MusicManager._active_players.size() == 3, "expected 3 outro players, got %d" % MusicManager._active_players.size())
	var outro_bass_stem: MusicStem = track.outro.filter(func(s): return s.name == &"bass")[0]
	var outro_bass_player: AudioStreamPlayer = MusicManager._active_players[&"bass"]
	assert(outro_bass_player.stream == outro_bass_stem.stream, "outro bass player stream mismatch")
	print("5. stop() near boundary -> waits, then plays outro: OK")

	print("ALL ASSERTIONS PASSED")
	get_tree().quit()
