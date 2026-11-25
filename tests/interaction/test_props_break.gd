extends AiTestCase
## A crate is hit and broken BG3-style (Breakable): an attack lands on it
## through the same use_ability a unit takes, a blast catches it, and at
## 0 HP it leaves the tree and the navigation grid where it stood.

const BOX: PackedScene = preload("res://systems/interaction_system/movable_box.tscn")
const CRATE: PackedScene = preload("res://systems/interaction_system/props/crate.tscn")


func run() -> void:
	var attacker: Unit = spawn_unit(&"player", 14, 30, 20, [melee()], Vector3.ZERO)
	var box: Node3D = BOX.instantiate()
	_root.add_child(box)
	box.global_position = Vector3(0, 0, -1.2)
	await get_tree().physics_frame
	var prop: Breakable = Breakable.of(box)
	check("the box is breakable, 10 lb -> 9 HP", prop != null and prop.full_hp() == 9,
		str(prop.full_hp() if prop else -1))

	var result: Dictionary = await attacker.use_ability(melee(), prop)
	check("an attack on the box lands on it", prop.hp < prop.full_hp() or result.get("damage", 0) == 0,
		"%d/%d %s" % [prop.hp, prop.full_hp(), str(result)])

	while attacker.is_busy():
		await get_tree().process_frame
	attacker.reset_turn_actions()
	var healed: Dictionary = await attacker.use_ability(load("res://data/abilities/heal.tres"), prop)
	check("a heal on the box is refused", healed.get("invalid_target", false), str(healed))
	var stood: Vector3 = prop.ground_point()

	var blast: Ability = load("res://data/abilities/explosive_fireball.tres")
	var caught: Array[Breakable] = blast.targeting.breakables_caught(attacker, box.global_position + Vector3(1, 0, 0))
	check("a blast beside the box catches it", caught.has(prop))
	var far: Array[Breakable] = blast.targeting.breakables_caught(attacker, box.global_position + Vector3(40, 0, 0))
	check("a blast far off does not", not far.has(prop))

	var before: int = prop.hp
	var dealt: int = prop.injure(4, DamageResolver.WoundType.CRUSHING)
	check("DR 1 comes off a blow", dealt == 3 and prop.hp == before - 3, "%d dealt" % dealt)

	prop.take_damage(prop.hp)
	check("at 0 HP it breaks and leaves the tree", not is_instance_valid(box) or not box.is_inside_tree())
	check("debris is left where it stood", _root.find_child("Debris0", false, false) != null)
	check("a broken box can no longer be targeted", not prop.is_alive() if is_instance_valid(prop) else true)
	check("a broken box still knows where it stood", not is_instance_valid(prop) or prop.ground_point().is_equal_approx(stood),
		str(prop.ground_point()) if is_instance_valid(prop) else "freed")

	# A crate saves what it holds and how damaged it is (MovableProp.save_state).
	var crate: MovableProp = CRATE.instantiate()
	_root.add_child(crate)
	StashComponent.find_on(crate).roll_loot()
	Breakable.of(crate).take_damage(3)
	var saved: Dictionary = crate.save_state()
	var reloaded: MovableProp = CRATE.instantiate()
	reloaded.load_state(saved)
	check("a reloaded crate keeps its loot and its damage", saved.has("stash") and saved.get("hp", 0) > 0
		and reloaded.save_state() == saved, str(saved))
	reloaded.free()
	crate.queue_free()
	free_spawned()
