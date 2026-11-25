extends AiTestCase
## Oil barrels (Breakable spill + explosion): smashed cold, one spills oil
## where it stood; set alight, one goes off, burning who stands close and
## setting off the oil barrel beside it a beat later.

const OIL: PackedScene = preload("res://systems/interaction_system/props/oil_barrel.tscn")
const CRATE: PackedScene = preload("res://systems/interaction_system/props/crate.tscn")


func run() -> void:
	var bystander: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(10, 0, 1.5))
	var context: WorldContext = WorldManager.context_for(bystander)
	var cold: Breakable = _place(OIL, Vector3(-10, 0, 0))
	var first: Breakable = _place(OIL, Vector3(10, 0, 0))
	var second: Breakable = _place(OIL, Vector3(12, 0, 0))
	var crate: Breakable = _place(CRATE, Vector3(10, 0, -1.5))
	await get_tree().physics_frame
	var grease: Surface = load("res://data/surfaces/grease.tres")

	cold.take_damage(cold.hp)
	check("an oil barrel smashed cold spills oil", SurfaceManager.surface_at(Vector3(-10, 0, 0), context) == grease,
		str(SurfaceManager.surface_at(Vector3(-10, 0, 0), context)))

	var hp: int = bystander.get_pool(StatIds.HP)
	var crate_hp: int = crate.hp
	first.ignite()
	check("set alight it goes off", not first.is_alive())
	check("the blast burns who stands close", bystander.get_pool(StatIds.HP) < hp)
	check("and the crate beside it", not crate.is_alive() or crate.hp < crate_hp)
	var left: Surface = SurfaceManager.surface_at(Vector3(10, 0, 0), context)
	check("it leaves fire on the ground, not oil", left != null and left.resource_path.ends_with("fire.tres"), str(left))
	check("the next barrel waits a beat", second.is_alive())
	await get_tree().create_timer(PropExplosion.CHAIN_DELAY + 0.2).timeout
	# A broken prop is freed with its Breakable.
	check("then goes off too", not is_instance_valid(second) or not second.is_alive())
	free_spawned()


func _place(scene: PackedScene, at: Vector3) -> Breakable:
	var prop: Node3D = scene.instantiate()
	_root.add_child(prop)
	prop.global_position = at
	return Breakable.of(prop)
