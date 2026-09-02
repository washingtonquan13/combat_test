class_name ProjectileStep
extends VfxStep
## Animates a visual (a mesh/particle scene — a glowing orb, an arrow,
## whatever fits) flying from the caster's position to the target's,
## over a fixed duration or at a fixed speed. ALWAYS blocks the next
## step — that's the entire point of a projectile step: whatever comes
## after it (typically a SpawnParticleStep for the impact) shouldn't
## happen until the projectile has actually visually arrived.
##
## This is purely visual timing, not gameplay timing — see unit_vfx.gd's
## header for why. The projectile takes real time to fly; the damage it
## visually represents was already applied the instant use_ability()
## resolved, before this sequence even started playing. What this step
## DOES fix is the projectile itself looking real (genuine travel time)
## rather than an explosion just happening instantly at both ends.
##
## Reuses the same parabolic arc math MoveCasterEffect.arc_point() uses
## for Jump — same shape, different purpose (a purely cosmetic flight
## path here, versus Jump's actual gameplay movement) — duplicated
## rather than shared, since sharing would mean this purely-visual step
## depending on a gameplay-movement class for an unrelated reason.

@export var projectile_scene: PackedScene
## Fixed flight time in seconds. If 0, speed is used instead to compute
## duration from distance, so the same step can either feel consistent
## regardless of range (fixed duration) or feel physically real (fixed
## speed) depending on which fits the ability better.
@export var duration: float = 0.0
@export var speed: float = 15.0
@export var arc_height: float = 0.0
## Some projectile assets carry their OWN baked-in root transform in the
## source .tscn (several in the BinbunVFX projectile family do, this
## wave projectile included) — there specifically to correctly orient
## their child meshes relative to Godot's -Z forward convention, as part
## of the asset's actual design. Rotating the instantiated scene's root
## directly (via look_at()) would overwrite that baked transform
## entirely, discarding it — no single facing_offset_degrees value can
## reliably compensate for that, since what's being destroyed isn't
## necessarily a pure yaw rotation relative to whatever look_at()
## produces. Instead, the instance is parented under a neutral wrapper
## Node3D that WE rotate — the instance underneath keeps its own
## original, untouched local transform exactly as authored, and only
## the wrapper ever points toward the target.
@export var facing_offset_degrees: float = 0.0


func play(context: Node, from: Vector3, to: Vector3, _ability: Ability = null, _caster: Unit = null) -> void:
	if not projectile_scene:
		return

	var wrapper := Node3D.new()
	WorldManager.spawn_parent().add_child(wrapper)

	var instance := projectile_scene.instantiate()
	wrapper.add_child(instance)

	var flight_time: float = duration if duration > 0.0 else from.distance_to(to) / max(speed, 0.01)

	var tween: Tween = context.create_tween()
	tween.tween_method(
		func(t: float):
			if is_instance_valid(wrapper):
				_update_transform(wrapper, from, to, t),
		0.0, 1.0, flight_time
	)
	await tween.finished

	if is_instance_valid(wrapper):
		wrapper.queue_free()  # frees the instance too, as its child


## Updates position AND rotation together each frame — rotation follows
## the arc's INSTANTANEOUS direction of travel (a tiny forward-sample
## along the curve), not just the fixed overall from->to direction, so a
## projectile with real arc_height visually banks through its curve
## instead of staying pointed at the destination the whole flight. For a
## straight shot (arc_height = 0, the default) the tangent direction
## never actually changes, so this reduces to the same result either way.
func _update_transform(wrapper: Node3D, from: Vector3, to: Vector3, t: float) -> void:
	var current: Vector3 = _arc_point(from, to, t)
	wrapper.global_position = current

	var look_t: float = min(t + 0.01, 1.0)
	var ahead: Vector3 = _arc_point(from, to, look_t)

	if ahead.distance_to(current) > 0.001:
		wrapper.look_at(ahead, Vector3.UP)
		if facing_offset_degrees != 0.0:
			wrapper.rotate_object_local(Vector3.UP, deg_to_rad(facing_offset_degrees))


func _arc_point(from: Vector3, to: Vector3, t: float) -> Vector3:
	var point: Vector3 = from.lerp(to, t)
	point.y += arc_height * 4.0 * t * (1.0 - t)
	return point


func describe() -> String:
	return "Projectile: %s" % ("fixed %.1fs" % duration if duration > 0.0 else "%.1f m/s" % speed)
