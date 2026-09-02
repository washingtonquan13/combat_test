class_name SfxLayer
extends Resource
## ONE sound within an SfxCue — a stream plus its own optional delay,
## volume, and pitch. Several layers combined in one SfxCue's `layers`
## array play TOGETHER (each independently timed, not sequentially
## blocking each other) — this is what lets a single moment (a launch,
## an impact) be more than one bare AudioStream: a whoosh AND a chime,
## the chime staggered slightly behind the whoosh, at a lower volume.
##
## No position offset field here (no "at caster / at target" concept
## like SpawnParticleStep/PlaySoundStep have) — position is decided once
## by whatever's calling SfxCue.play() (unit_sfx.gd), which already
## knows correctly whether a given moment belongs at the attacker or the
## target. Keeping that decision in one place rather than duplicating it
## per layer.

@export var stream: AudioStream
@export var delay: float = 0.0
@export_range(-80.0, 24.0, 0.1) var volume_db: float = 0.0
@export_range(0.5, 2.0, 0.01) var pitch_scale: float = 1.0


## Fire-and-forget — the delay (if any) happens independently in the
## background; this never blocks whatever called it.
func play(context: Node, position: Vector3) -> void:
	if not stream:
		return
	if delay > 0.0:
		await context.get_tree().create_timer(delay).timeout
	_spawn(context, position)


func _spawn(context: Node, position: Vector3) -> void:
	var player := AudioStreamPlayer3D.new()
	context.add_child(player)
	player.stream = stream
	player.global_position = position
	player.volume_db = volume_db
	player.pitch_scale = pitch_scale
	player.play()
	player.finished.connect(player.queue_free)
