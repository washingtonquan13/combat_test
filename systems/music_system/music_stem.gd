class_name MusicStem
extends Resource
## ONE instrument layer within a MusicTrack phase (intro/loop/outro) —
## a stream plus its own mix volume, and critically a NAME. The name is
## what lets a future dynamic-layering feature address "the drums
## layer" directly (fade it in/out by key) instead of by array position,
## which breaks the moment a stem gets reordered or another one gets
## added. Same "wrap a bare stream so it can carry more than itself"
## reasoning SfxLayer already uses for SFX — mirrors that file's shape
## on purpose, not a coincidence.
##
## No pitch_scale, unlike SfxLayer — pitch-shifting one stem out of a
## synchronized set would desync it from the others, which SfxLayer's
## independent one-shots never have to worry about.

@export var name: StringName = &""
@export var stream: AudioStream
@export_range(-80.0, 24.0, 0.1) var volume_db: float = 0.0
