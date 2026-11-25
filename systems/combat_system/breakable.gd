class_name Breakable
extends Node3D
## What makes a prop something that can be hit and broken, BG3-style: a
## crate, a barrel. A child of the prop (an InteractableProp or a
## MovableProp), at its origin, and itself what an attack targets - the
## same `target` a Unit is to use_ability, so to-hit, damage and the
## combat log run through the one path. Not a Unit: it has no turn, no
## defense, no stats; the AI ignores it.
##
## Numbers are GURPS's (B557-559, Damage to Objects):
## - HP: 4 x the cube root of its weight in lb (B558), so a 30 lb crate
##   has 12. BG3's crate has 4; ours lasts a few hits, like a GURPS one.
## - DR: its material's (B558 table: thin wood 1-2, oak 3, iron 10).
## - Injury: Unliving or Homogeneous (B380), its injury_preset - a hollow
##   crate is Unliving (impaling x1, piercing small).
## - Vulnerability (B161): what it takes double from, a wooden thing's
##   fire. The tooltip's "weak to".
## It is never hit in a location; every hit is the torso row.
##
## Breaking (0 HP or less): it is recorded as removed from the area
## (AreaState, as a dead unit is), leaves debris, drops what its
## StashComponent held as a LootPile, re-bakes the navigation grid where
## it stood, and is freed. Damage short of that is not saved.
##
## What hurts it: single-target attacks (UnitCombat.use_ability), area
## spells (AbilityTargeting.breakables_caught), and ground surfaces each
## round (SurfaceManager._burn_breakables).

const UNLIVING: InjuryPreset = preload("res://data/injury_presets/unliving.tres")
## The right-click Attack its prop offers. Loaded, not preloaded: its
## script names this class.
const ATTACK_PATH: String = "res://data/interactions/attack.tres"

## Debris chunks per break, and how long they tumble before they are
## frozen where they lie.
const DEBRIS_PIECES: int = 6
const DEBRIS_SETTLE_SECONDS: float = 3.0

signal damaged(amount: int)
signal broken

@export var display_name: String = "Crate"
## In lb. 0 takes the prop's own (MovableProp.weight_lb).
@export var weight_lb: float = 0.0
## 0 is the GURPS rule above, from the weight.
@export var max_hp: int = 0
@export var dr: int = 1
@export var injury_preset: InjuryPreset = UNLIVING
## GURPS Vulnerability (B161): damage of these types is doubled after DR.
@export var vulnerable_to: Array[DamageResolver.WoundType] = []
## Debris colour; the prop's first mesh's if left clear.
@export var debris_color: Color = Color(0, 0, 0, 0)

var hp: int = 0

var _profile: InjuryProfile
var _broken: bool = false
var _last_box: AABB


func _ready() -> void:
	add_to_group("breakables")
	if hp <= 0:
		hp = full_hp()
	_offer_attack()


## Puts Attack on the prop's right-click menu, so a prop that breaks never
## needs it authored. A fresh array: the scene's own is not touched.
func _offer_attack() -> void:
	var p := prop()
	if p == null or not "interactions" in p:
		return
	var attack: InteractionOption = load(ATTACK_PATH)
	if attack == null or p.interactions.has(attack):
		return
	var list: Array[InteractionOption] = p.interactions.duplicate()
	list.append(attack)
	p.interactions = list


## The Breakable on node: itself, or a direct child of it (a prop).
static func of(node) -> Breakable:
	if node is Breakable:
		return node
	if not node is Node or not is_instance_valid(node):
		return null
	for child in (node as Node).get_children():
		if child is Breakable:
			return child
	return null


## Whether ability can be aimed at a prop: one that is not for allies and
## deals damage. Everything else (a heal, a shove, a sleep dart) has
## nothing to do to a crate.
static func hurt_by(ability: Ability) -> bool:
	if ability == null or ability.targeting == null or ability.targeting.requires_ally_target():
		return false
	for effect in ability.effects:
		if effect and effect.harms():
			return true
	return false


func prop() -> Node3D:
	return get_parent() as Node3D


func weight() -> float:
	if weight_lb > 0.0:
		return weight_lb
	var p := prop()
	if p is MovableProp:
		return (p as MovableProp).weight_lb
	return 10.0


func full_hp() -> int:
	if max_hp > 0:
		return max_hp
	return maxi(roundi(4.0 * pow(maxf(weight(), 0.01), 1.0 / 3.0)), 1)


func is_alive() -> bool:
	return not _broken and hp > 0 and is_inside_tree()


## Same shape as Unit.injury_profile, for DamageResolver.
func injury_profile() -> InjuryProfile:
	if _profile == null:
		_profile = InjuryProfile.build(BodyPlan.human(), injury_preset)
		for type in vulnerable_to:
			_profile.torso.multipliers[type] *= 2.0
	return _profile


## The multiplier a hit of wound_type meets (after DR), for the tooltip.
func multiplier(wound_type: DamageResolver.WoundType) -> float:
	return injury_profile().torso.multipliers[wound_type]


## Same shape as Unit.take_damage. Breaks it at 0 HP.
func take_damage(amount: int, _critical: bool = false) -> void:
	if not is_alive() or amount <= 0:
		return
	hp -= amount
	damaged.emit(amount)
	SystemLog.print("%s takes %d damage (%d/%d HP)." % [display_name, amount, maxi(hp, 0), full_hp()])
	if hp <= 0:
		break_apart()


## Rolled damage of a type, through DR and the profile: what a blast or
## a surface does to it.
func injure(raw: int, wound_type: DamageResolver.WoundType, armor_divisor: float = 1.0, ignores_dr: bool = false) -> int:
	var amount: int = DamageResolver.injury(raw, self, wound_type, armor_divisor, false, ignores_dr, null, true)
	take_damage(amount)
	return amount


## The world box round the prop's collision shapes - what the grid baked,
## what a blast reaches and a reach is measured to.
func box() -> AABB:
	# Out of the tree it has no transform: the box it had when it broke,
	# for what lands after (a fire bolt lighting where it stood).
	if _broken or not is_inside_tree():
		return _last_box
	var p := prop()
	if p is MovableProp:
		return (p as MovableProp).grid_aabb()
	var result := AABB(global_position, Vector3.ZERO)
	if p:
		for child in p.get_children():
			if child is CollisionShape3D and child.shape != null:
				result = result.merge(child.global_transform * child.shape.get_debug_mesh().get_aabb())
	return result


## Where a shot at it lands: the middle of the box.
func aim_point() -> Vector3:
	return box().get_center()


## The floor under its middle, for what touches the ground (a fire bolt
## lighting what it struck).
func ground_point() -> Vector3:
	var b := box()
	return Vector3(b.get_center().x, b.position.y, b.get_center().z)


## The box's point nearest point.
func closest_point(point: Vector3) -> Vector3:
	var b := box()
	return point.clamp(b.position, b.end)


## The gap from unit's body to the box: the distance a reach or a range is
## measured across, as Unit.edge_distance_to is between two bodies.
func gap_from(unit: Unit) -> float:
	var body: UnitBody = unit.body_shape()
	var middle: Vector3 = (body.column_low() + body.column_high()) * 0.5
	return body.distance_to_point(closest_point(middle))


## The rule for 0 HP: see the header.
func break_apart() -> void:
	if _broken:
		return
	var p := prop()
	var was: AABB = box()
	_last_box = was
	_broken = true
	var root: Node = _world_root()
	var parent: Node = p.get_parent() if p else null
	if p and "persistent_id" in p and p.persistent_id != &"" and WorldManager.current_area():
		AreaState.mark_removed(WorldManager.current_area().id, p.persistent_id)
	SystemLog.print("%s breaks." % display_name)
	broken.emit()
	if parent:
		_spawn_debris(parent, was)
		_drop_contents(parent, was)
	if p:
		# Out of the tree first, so the re-bake no longer sees it.
		p.get_parent().remove_child(p)
		NavigationGrid.invalidate_region(root, was)
		p.queue_free()


func _world_root() -> Node:
	var p := prop()
	var ctx: WorldContext = WorldManager.context_for(p if p else self)
	if ctx and ctx.world_root and ctx.contains(p if p else self):
		return ctx.world_root
	return p if p else self


## What the prop's StashComponent held, as a LootPile where it stood.
## Rolled first if it never was, so a crate broken unopened still drops
## its loot. Nothing is left when it held nothing.
func _drop_contents(parent: Node, was: AABB) -> void:
	var stash: StashComponent = StashComponent.find_on(prop())
	if stash == null:
		return
	stash.roll_loot()
	if stash.inventory.get_container().items().is_empty():
		return
	var pile := LootPile.new()
	pile.name = "%sLoot" % display_name.replace(" ", "")
	parent.add_child(pile)
	pile.global_position = Vector3(was.get_center().x, was.position.y, was.get_center().z)
	pile.take(stash, display_name)


## Pieces the size of a slat, thrown out a little from where it stood,
## that fall and then freeze. Physics only among themselves and the
## world: they block nothing and the grid never sees them.
func _spawn_debris(parent: Node, was: AABB) -> void:
	var color: Color = debris_color if debris_color.a > 0.0 else _prop_color()
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.9
	var span: float = maxf(was.size.x, was.size.z)
	var piece_size := Vector3(span * 0.6, maxf(span * 0.06, 0.02), maxf(span * 0.15, 0.04))
	var centre: Vector3 = was.get_center()
	var pieces: Array[RigidBody3D] = []
	for i in DEBRIS_PIECES:
		var body := RigidBody3D.new()
		body.name = "Debris%d" % i
		body.collision_layer = Corpse.BODY_LAYER
		body.collision_mask = Corpse.WORLD_MASK | Corpse.BODY_LAYER
		body.mass = maxf(weight() / DEBRIS_PIECES * 0.45, 0.1)
		var shape := CollisionShape3D.new()
		var cube := BoxShape3D.new()
		cube.size = piece_size
		shape.shape = cube
		body.add_child(shape)
		var mesh := MeshInstance3D.new()
		var box_mesh := BoxMesh.new()
		box_mesh.size = piece_size
		box_mesh.material = material
		mesh.mesh = box_mesh
		body.add_child(mesh)
		parent.add_child(body)
		var angle: float = TAU * i / DEBRIS_PIECES
		var out := Vector3(cos(angle), 0, sin(angle))
		body.global_position = centre + out * span * 0.2 + Vector3(0, (i % 3) * piece_size.y * 2.0, 0)
		body.rotation = Vector3(0, angle, (i % 2) * 0.4)
		body.linear_velocity = out * 1.5 + Vector3(0, 1.5, 0)
		body.angular_velocity = Vector3(out.z, 0, -out.x) * 4.0
		pieces.append(body)
	var tree := parent.get_tree()
	if tree:
		tree.create_timer(DEBRIS_SETTLE_SECONDS).timeout.connect(func():
			for body in pieces:
				if is_instance_valid(body):
					body.freeze = true)


func _prop_color() -> Color:
	var p := prop()
	if p:
		for mesh: MeshInstance3D in p.find_children("*", "MeshInstance3D", true, false):
			var material: Material = mesh.get_active_material(0)
			if material is StandardMaterial3D:
				return (material as StandardMaterial3D).albedo_color
	return Color(0.45, 0.32, 0.2)
