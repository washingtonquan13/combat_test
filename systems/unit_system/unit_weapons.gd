class_name UnitWeapons
extends Node
## Puts the drawn weapons in the body's hands - the held counterpart of
## UnitAnimator, wired the same way and deciding nothing.
##
## Both weapon sets are live at once (UnitCombat.combat_abilities), but
## a body has two hands, so one set is DRAWN: whichever kind the unit
## last attacked with, melee to start with, or ranged when only ranged
## is held. Each held item's WeaponData.model_scene goes on the body's
## grip for its hand (CharacterModel.main_hand_grip / off_hand_grip).
## A body without grips - a demon whose claws are its body - holds
## nothing, and a weapon without a model shows nothing.

## What's in the hands changed, and with it maybe the stance.
signal stance_changed(stance: String)

@export var unit: Unit

var drawn: AttackRow.Kind = AttackRow.Kind.MELEE
## Hand slot -> the model instance standing in for what's in it.
var _held: Dictionary = {}


func _ready() -> void:
	if not unit:
		unit = get_parent() as Unit
	unit.equipment_changed.connect(_on_equipment_changed)
	unit.ability_use_started.connect(_on_ability_use_started)
	# Deferred: equipment restored from a save or authored on the unit
	# lands after the unit's own _ready, without equipment_changed.
	refresh.call_deferred()


## The model in a hand slot, or null.
func held_model(slot: EquipSlot.Slot) -> Node3D:
	var model: Node3D = _held.get(slot)
	return model if is_instance_valid(model) else null


## The stance clip of what's in the hands (WeaponData.stance_animation):
## the off hand's if it names one, else the main hand's. Only what is
## actually held counts - a body without grips stands as it always does.
func stance() -> String:
	for off_hand in [true, false]:
		var slot: EquipSlot.Slot = _hand_slot(drawn, off_hand)
		var weapon: WeaponData = _weapon_in(slot)
		if weapon and weapon.stance_animation != "" and held_model(slot):
			return weapon.stance_animation
	return ""


## Draws the set of `kind`, if anything of that kind is held.
func draw(kind: AttackRow.Kind) -> void:
	if kind != drawn and _holds(kind):
		drawn = kind
		refresh()


## Rebuilds what's in the hands from what's equipped.
func refresh() -> void:
	for model in _held.values():
		if is_instance_valid(model):
			model.queue_free()
	_held.clear()
	var body := unit.get_node_or_null("CharacterModel") as CharacterModel
	if body == null:
		return
	if not _holds(drawn):
		var other := AttackRow.Kind.RANGED if drawn == AttackRow.Kind.MELEE else AttackRow.Kind.MELEE
		if _holds(other):
			drawn = other
	for off_hand in [false, true]:
		var slot: EquipSlot.Slot = _hand_slot(drawn, off_hand)
		var weapon: WeaponData = _weapon_in(slot)
		if weapon == null or weapon.model_scene == null:
			continue
		var grip: Node3D = body.off_hand_grip if off_hand != weapon.held_in_off_hand else body.main_hand_grip
		if not is_instance_valid(grip):
			continue
		var model: Node3D = weapon.model_scene.instantiate()
		grip.add_child(model)
		_held[slot] = model
	stance_changed.emit(stance())


func _holds(kind: AttackRow.Kind) -> bool:
	return _weapon_in(_hand_slot(kind, false)) != null or _weapon_in(_hand_slot(kind, true)) != null


## UnitCombat._hand_slot's mapping. Not called through UnitCombat: this
## script loads with unit.tscn, and naming UnitCombat here compiles it
## mid-load, before the status resources its constants preload.
static func _hand_slot(kind: AttackRow.Kind, off_hand: bool) -> EquipSlot.Slot:
	if kind == AttackRow.Kind.MELEE:
		return EquipSlot.Slot.MELEE_OFF_HAND if off_hand else EquipSlot.Slot.MELEE_MAIN_HAND
	return EquipSlot.Slot.RANGED_OFF_HAND if off_hand else EquipSlot.Slot.RANGED_MAIN_HAND


func _weapon_in(slot: EquipSlot.Slot) -> WeaponData:
	var item: ItemInstance = unit.get_equipped_item(slot)
	var gear := item.definition as GearItem if item else null
	return gear.weapon_data if gear else null


func _on_equipment_changed(_unit: Unit) -> void:
	refresh()


func _on_ability_use_started(_attacker: Unit, _target, ability: Ability) -> void:
	for effect in ability.effects:
		if effect is GearDamageEffect:
			draw(effect.kind())
			return
		# Reloading takes the gun in hand; guns are ranged weapons.
		if effect is ReloadEffect:
			draw(AttackRow.Kind.RANGED)
			return
