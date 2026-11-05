class_name UnitWeapons
extends Node
## Shows every equipped weapon on the body - the held and carried
## counterpart of UnitAnimator, wired the same way and deciding nothing.
##
## Which set is drawn, and whether anything is, is the Unit's to say
## (Unit.active_weapon_set, Unit.weapons_sheathed, both announced by
## Unit.loadout_changed); this only renders it. The active set's
## WeaponData.model_scene goes on the body's grip for each hand
## (CharacterModel.main_hand_grip / off_hand_grip); everything else
## equipped - the other set, and the active one too while sheathed - is
## carried on the body's sheath sockets (CharacterModel.sheath_socket):
## across the back or on a hip, by WeaponData.resolved_sheath(). A body
## without grips - a demon whose claws are its body - holds and carries
## nothing, and a weapon without a model shows nothing.

## What's in the hands changed, and with it maybe the stance.
signal stance_changed(stance: String)

## Every hand slot, in the order homes are handed out.
const SLOTS: Array[EquipSlot.Slot] = [
	EquipSlot.Slot.MELEE_MAIN_HAND, EquipSlot.Slot.MELEE_OFF_HAND,
	EquipSlot.Slot.RANGED_MAIN_HAND, EquipSlot.Slot.RANGED_OFF_HAND,
]
## Where along a carried item's length, from its handle end, sits on the
## socket's origin: the middle on the back, about the guard on a hip -
## the hilt rides above the belt, the blade hangs below.
const BACK_ANCHOR: float = 0.5
const HIP_ANCHOR: float = 0.18
## Air between a carried item and the body, so it lies on the surface
## rather than in it.
const SURFACE_GAP: float = 0.01

@export var unit: Unit

## The kind of the active set - mirrors Unit.active_weapon_set.
var drawn: AttackRow.Kind = AttackRow.Kind.MELEE
## Hand slot -> the model instance standing in for what's in it.
var _held: Dictionary = {}
## Hand slot -> the model instance carried on the body for it.
var _carried: Dictionary = {}
## What the last refresh showed, to skip rebuilding when nothing visible
## changed (loadout_changed also fires for abilities).
var _shown: Array = []

## PackedScene -> its fitted bounds (see _fit); measured once per scene.
static var _bounds_cache: Dictionary = {}


func _ready() -> void:
	if not unit:
		unit = get_parent() as Unit
	unit.loadout_changed.connect(_on_loadout_changed)
	# Deferred: equipment restored from a save or authored on the unit
	# lands after the unit's own _ready, without a signal.
	refresh.call_deferred()


## The model in a hand slot, or null.
func held_model(slot: EquipSlot.Slot) -> Node3D:
	var model: Node3D = _held.get(slot)
	return model if is_instance_valid(model) else null


## The model carried on the body for a hand slot's weapon, or null.
func carried_model(slot: EquipSlot.Slot) -> Node3D:
	var model: Node3D = _carried.get(slot)
	return model if is_instance_valid(model) else null


## The stance clip of what's in the hands (WeaponData.stance_animation):
## the off hand's if it names one, else the main hand's. Only what is
## actually held counts - sheathed, or a body without grips, stands as it
## always does.
func stance() -> String:
	for off_hand in [true, false]:
		var slot: EquipSlot.Slot = _hand_slot(drawn, off_hand)
		var weapon: WeaponData = _weapon_in(slot)
		if weapon and weapon.stance_animation != "" and held_model(slot):
			return weapon.stance_animation
	return ""


## Rebuilds what's in the hands and on the body from the Unit's state.
func refresh() -> void:
	if not is_instance_valid(unit):
		return
	drawn = unit.active_weapon_set
	var body := unit.get_node_or_null("CharacterModel") as CharacterModel
	var shown: Array = [body, unit.weapons_sheathed, drawn]
	for slot in SLOTS:
		var gear: GearItem = _gear_in(slot)
		shown.append(gear.weapon_data if gear else null)
	if shown == _shown and _all_alive():
		return
	_shown = shown
	_clear()
	if body:
		var homes: Dictionary = _homes(body)
		for slot in SLOTS:
			var weapon: WeaponData = _weapon_in(slot)
			if weapon == null or weapon.model_scene == null:
				continue
			if not unit.weapons_sheathed and _kind_of(slot) == drawn:
				_hold(body, slot, weapon)
			elif homes.has(slot):
				_carry(homes[slot], slot, weapon)
	stance_changed.emit(stance())


func _hold(body: CharacterModel, slot: EquipSlot.Slot, weapon: WeaponData) -> void:
	var grip: Node3D = body.off_hand_grip if _is_off_hand(slot) != weapon.held_in_off_hand else body.main_hand_grip
	if not is_instance_valid(grip):
		return
	var model: Node3D = weapon.model_scene.instantiate()
	grip.add_child(model)
	Unit.wear_render_layer(model)
	_held[slot] = model


## home: {"socket": Node3D, "hip": bool, "lift": float}.
func _carry(home: Dictionary, slot: EquipSlot.Slot, weapon: WeaponData) -> void:
	var model: Node3D = weapon.model_scene.instantiate()
	var fit: Dictionary = _fit(weapon.model_scene, model)
	var long: Vector3 = fit["long"]
	var out: Vector3 = fit["out"]
	var center: Vector3 = fit["center"]
	var is_hip: bool = home["hip"]
	var lift: float = home["lift"]
	var socket: Node3D = home["socket"]
	var along: float = lerpf(fit["handle_end"], fit["tip_end"], HIP_ANCHOR if is_hip else BACK_ANCHOR)
	var inner: float = fit["inner"]
	# The point on the item that sits on the socket: `along` its length,
	# on its body-side face, centred across its width.
	var anchor_point: Vector3 = center + long * (along - center.dot(long)) + out * (inner - center.dot(out))
	# Socket frame: +X away from the body, +Y the handle end's way.
	var handle: Vector3 = -long
	var to_socket: Basis = Basis(out, handle, out.cross(handle)).transposed()
	model.transform = Transform3D(to_socket, Vector3(SURFACE_GAP + lift, 0.0, 0.0) - to_socket * anchor_point)
	socket.add_child(model)
	Unit.wear_render_layer(model)
	_carried[slot] = model


## Hand slot -> where its weapon is carried when it isn't in hand, for
## EVERY equipped weapon, drawn or not: each has one home for as long as
## the loadout stands, so swapping sets doesn't shuffle the rest around
## the body. Two never share a socket; the second item across the back
## lies over the first, lifted by its thickness.
func _homes(body: CharacterModel) -> Dictionary:
	var homes: Dictionary = {}
	var taken: Dictionary = {}
	var back_depth: float = 0.0
	for slot in SLOTS:
		var gear: GearItem = _gear_in(slot)
		var weapon: WeaponData = gear.weapon_data if gear else null
		if weapon == null or weapon.model_scene == null:
			continue
		var main_side: bool = _is_off_hand(slot) == weapon.held_in_off_hand
		var hips: Array = [CharacterModel.SheathSocket.HIP_MAIN, CharacterModel.SheathSocket.HIP_OFF]
		if not main_side:
			hips.reverse()
		var backs: Array = [CharacterModel.SheathSocket.BACK_A, CharacterModel.SheathSocket.BACK_B]
		var order: Array = backs + hips if weapon.resolved_sheath(gear.is_shield) == WeaponData.Sheath.BACK else hips + backs
		for which: CharacterModel.SheathSocket in order:
			if taken.has(which):
				continue
			var socket: Node3D = body.sheath_socket(which)
			if socket == null:
				continue
			taken[which] = true
			var hip: bool = which == CharacterModel.SheathSocket.HIP_MAIN or which == CharacterModel.SheathSocket.HIP_OFF
			var lift: float = 0.0
			if which == CharacterModel.SheathSocket.BACK_A:
				back_depth = _fit(weapon.model_scene, null)["thickness"]
			elif which == CharacterModel.SheathSocket.BACK_B:
				lift = back_depth
			homes[slot] = {"socket": socket, "hip": hip, "lift": lift}
			break
	return homes


## How a weapon scene lies: its bounds' longest axis is its length
## ("long", unit, pointing from the handle end - the end nearer the
## grip, the scene's origin - to the tip), its thinnest is its flat
## ("out", pointing to the fuller side: a shield's boss faces away from
## the back). "handle_end"/"tip_end" are coordinates along "long",
## "inner" the body-side face along "out". `model` may be null when the
## scene was measured before.
func _fit(scene: PackedScene, model: Node3D) -> Dictionary:
	if _bounds_cache.has(scene):
		return _bounds_cache[scene]
	var probe: Node3D = model if model else scene.instantiate()
	var box: AABB = _bounds(probe, Transform3D(), AABB(), [false])
	if probe != model:
		probe.free()
	var size: Vector3 = box.size
	var long_axis: int = size.max_axis_index()
	var thin_axis: int = size.min_axis_index()
	if long_axis == thin_axis:
		thin_axis = (long_axis + 1) % 3
	var lo: Vector3 = box.position
	var hi: Vector3 = box.end
	var long := Vector3.ZERO
	var handle_at_min: bool = absf(lo[long_axis]) <= absf(hi[long_axis])
	long[long_axis] = 1.0 if handle_at_min else -1.0
	var out := Vector3.ZERO
	var out_positive: bool = lo[thin_axis] + hi[thin_axis] >= 0.0
	out[thin_axis] = 1.0 if out_positive else -1.0
	var fit: Dictionary = {
		"long": long, "out": out, "center": box.get_center(),
		"handle_end": lo[long_axis] if handle_at_min else -hi[long_axis],
		"tip_end": hi[long_axis] if handle_at_min else -lo[long_axis],
		"inner": lo[thin_axis] if out_positive else -hi[thin_axis],
		"thickness": size[thin_axis],
	}
	_bounds_cache[scene] = fit
	return fit


## The merged bounds of every VisualInstance3D under node, in the space
## node's transforms are taken from. found[0] says whether any was.
static func _bounds(node: Node, to_root: Transform3D, box: AABB, found: Array) -> AABB:
	for child in node.get_children():
		if not child is Node3D:
			continue
		var t: Transform3D = to_root * (child as Node3D).transform
		if child is VisualInstance3D:
			var b: AABB = t * (child as VisualInstance3D).get_aabb()
			box = b if not found[0] else box.merge(b)
			found[0] = true
		box = _bounds(child, t, box, found)
	return box


func _clear() -> void:
	for model in _held.values() + _carried.values():
		if is_instance_valid(model):
			# Off the body at once: a muzzle search this frame (Character
			# Model._held_muzzle) must not find the outgoing gun.
			if model.get_parent():
				model.get_parent().remove_child(model)
			model.queue_free()
	_held.clear()
	_carried.clear()


func _all_alive() -> bool:
	for model in _held.values() + _carried.values():
		if not is_instance_valid(model):
			return false
	return true


static func _kind_of(slot: EquipSlot.Slot) -> AttackRow.Kind:
	if slot == EquipSlot.Slot.MELEE_MAIN_HAND or slot == EquipSlot.Slot.MELEE_OFF_HAND:
		return AttackRow.Kind.MELEE
	return AttackRow.Kind.RANGED


static func _is_off_hand(slot: EquipSlot.Slot) -> bool:
	return slot == EquipSlot.Slot.MELEE_OFF_HAND or slot == EquipSlot.Slot.RANGED_OFF_HAND


## UnitCombat._hand_slot's mapping. Not called through UnitCombat: this
## script loads with unit.tscn, and naming UnitCombat here compiles it
## mid-load, before the status resources its constants preload.
static func _hand_slot(kind: AttackRow.Kind, off_hand: bool) -> EquipSlot.Slot:
	if kind == AttackRow.Kind.MELEE:
		return EquipSlot.Slot.MELEE_OFF_HAND if off_hand else EquipSlot.Slot.MELEE_MAIN_HAND
	return EquipSlot.Slot.RANGED_OFF_HAND if off_hand else EquipSlot.Slot.RANGED_MAIN_HAND


func _gear_in(slot: EquipSlot.Slot) -> GearItem:
	var item: ItemInstance = unit.get_equipped_item(slot)
	return item.definition as GearItem if item else null


func _weapon_in(slot: EquipSlot.Slot) -> WeaponData:
	var gear: GearItem = _gear_in(slot)
	return gear.weapon_data if gear else null


func _on_loadout_changed(_unit: Unit) -> void:
	refresh()
