class_name PlaySoundStep
extends VfxStep
## Plays a sound at a fixed point in the sequence. Always non-blocking,
## same reasoning as SpawnParticleStep — use a DelayStep if something
## later needs to wait. Cleanup IS handled here (unlike particle
## scenes), since AudioStreamPlayer3D has a reliable finished signal
## regardless of what clip is assigned.

enum At { CASTER, TARGET }

@export var stream: AudioStream
@export var at: At = At.TARGET


func play(context: Node, from: Vector3, to: Vector3, _ability: Ability = null, _caster: Unit = null) -> void:
	if not stream:
		return

	var position: Vector3 = from if at == At.CASTER else to
	var player := AudioStreamPlayer3D.new()
	WorldManager.spawn_parent().add_child(player)
	player.stream = stream
	player.global_position = position
	player.play()
	player.finished.connect(player.queue_free)


func describe() -> String:
	return "Play sound at %s" % ("caster" if at == At.CASTER else "target")
