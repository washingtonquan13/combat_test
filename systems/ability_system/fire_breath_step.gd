class_name FireBreathStep
extends VfxStep
## Breathes a gust of fire (fire_breath.tscn) down the ability's cone,
## from the caster's chest along its aim. Returns at once: the gust frees
## itself when it has burnt out.

@export var scene: PackedScene = preload("res://systems/surface_system/fire_breath.tscn")


func play(context: Node, _from: Vector3, to: Vector3, ability: Ability = null, caster: Unit = null) -> void:
	if not scene or not ability or not is_instance_valid(caster):
		return
	var cone := ability.targeting as ConeTargeting
	if not cone:
		return
	var gust: Node3D = scene.instantiate()
	context.add_child(gust)
	gust.breathe(cone.origin(caster), cone.direction(caster, to), cone.length, cone.half_angle())


func describe() -> String:
	return "Breathes fire down the cone"
