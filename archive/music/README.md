# Archived: the WAV-stem music system

Replaced by the sfzplayer director (`addons/sfzplayer`, `music/transitions.json`),
which generates the music live instead of playing rendered files.

- `audio/`   the rendered stems and mixes the old system played
- `tracks/`  the MusicTrack resources: which stems made up each piece, and its loop points
- `scripts/` MusicTrack, MusicStem and MusicTrackDatabase, the classes those resources used

`archive/.gdignore` keeps Godot from importing or parsing any of this, so the
resources here no longer load in the editor. To bring a piece back, move it out
of the archive along with the scripts it uses.
