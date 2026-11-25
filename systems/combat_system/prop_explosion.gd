class_name PropExplosion
extends Resource
## What an explosive prop (an oil barrel) does when fire reaches it,
## BG3-style: it bursts, burning everyone and every prop within radius,
## lights the ground there, and sets off any other explosive prop it
## catches a moment later, so a row of barrels goes up one after another.
## A Breakable's `explosion`; see Breakable.ignite.
##
## The damage is GURPS's: dice rolled once per victim, through their DR
## and wounding multiplier as an area hit (DamageResolver.injury,
## is_area), so it never strikes a location. It has no attacker: nobody
## rolls to hit and nobody defends, and a blast out of combat does not
## start one.

## Seconds between one explosive prop going up and the next it caught.
const CHAIN_DELAY: float = 0.35
## The blast VFX is authored for this radius (fireball_explosion.tscn).
const VFX_AUTHORED_RADIUS: float = 3.0
## Seconds the VFX is left to play before it is freed: its "explode"
## animation's length.
const VFX_LIFETIME: float = 5.0

@export var dice_count: int = 3
@export var dice_sides: int = 6
@export var dice_bonus: int = 0
@export var wound_type: DamageResolver.WoundType = DamageResolver.WoundType.BURNING
## Metres from the prop's middle; a body or a box reaching into it is hit.
@export var radius: float = 3.0
## What it lays on the ground it reached (fire), and how far.
@export var leaves: Surface
@export var leaves_radius: float = 2.0
@export var vfx: PackedScene
@export var sound: SfxCue


func roll() -> int:
	var total: int = dice_bonus
	for _i in dice_count:
		total += randi_range(1, dice_sides)
	return total


## Goes off at centre. source is the prop going up, still in the tree,
## so the ground and the world it reaches are its own. Every unit and
## prop caught is hit now; explosive props caught go off CHAIN_DELAY
## later.
func detonate(source: Breakable, centre: Vector3) -> void:
	var tree: SceneTree = source.get_tree()
	var world: World3D = source.get_world_3d()
	var context: WorldContext = WorldManager.context_for(source)
	SystemLog.print("%s explodes!" % source.display_name)
	_play(source, centre)
	if leaves:
		SurfaceManager.spawn_burst(leaves, centre, leaves_radius, source)
	for unit in UnitQuery.living_units(tree):
		if unit.get_world_3d() != world or unit.body_shape().distance_to_point(centre) > radius:
			continue
		var amount: int = DamageResolver.injury(roll(), unit, wound_type, 1.0, false, false, null, true)
		SystemLog.print("The blast hits %s for %d." % [unit.display_name, amount])
		unit.take_damage(amount)
	for node in tree.get_nodes_in_group(&"breakables"):
		var prop := node as Breakable
		if prop == null or prop == source or not prop.is_alive():
			continue
		if WorldManager.context_for(prop) != context or prop.closest_point(centre).distance_to(centre) > radius:
			continue
		# An explosive prop is not hurt now, so it never goes off in this
		# same frame: it goes off a beat later, which is the chain you see.
		# Not heated now: ignite heats it if it can still go off, so one
		# whose world left the tree in the meantime isn't left primed.
		if prop.explosion:
			tree.create_timer(CHAIN_DELAY).timeout.connect(func():
				if is_instance_valid(prop):
					prop.ignite())
			continue
		prop.heat()
		prop.injure(roll(), wound_type, 1.0, false)


func _play(source: Breakable, centre: Vector3) -> void:
	var parent: Node = source.prop().get_parent() if source.prop() else WorldManager.spawn_parent()
	if sound:
		sound.play(parent, centre)
	if vfx == null:
		return
	var instance: Node = vfx.instantiate()
	if instance is Node3D:
		var factor: float = radius / VFX_AUTHORED_RADIUS
		(instance as Node3D).scale = Vector3.ONE * factor
	parent.add_child(instance)
	if instance is Node3D:
		(instance as Node3D).global_position = centre
	parent.get_tree().create_timer(VFX_LIFETIME).timeout.connect(func():
		if is_instance_valid(instance):
			instance.queue_free())
