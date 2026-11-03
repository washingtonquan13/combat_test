class_name UnitEquipment
extends RefCounted
## Owns which ItemInstance is equipped in which of this unit's EquipSlots — the
## per-unit storage that lets the SAME 16 EquipSlot nodes in
## party_overview.tscn show a different loadout depending on which
## unit's sheet is open (see party_overview.gd's open_for(), which
## rebuilds the slots' widgets from whichever unit is shown).
##
## Keyed by EquipSlot.Slot — a real, typed per-slot identity distinct
## from GearItem.SlotType (which only answers "what kind of item fits
## here," not "which specific slot is this"; SlotType.RING alone can't
## tell the two ring slots apart, which is exactly why Slot exists).
## Previously keyed by the EquipSlot node's own scene-tree name, which
## broke silently the moment any of the 16 slot nodes got renamed in
## the editor — a typed enum key can't drift out of sync with the scene
## the way a hand-matched string could.
##
## Takes owner: Unit because equip()/unequip() call back into
## register_stat_modifier()/unregister_stat_modifier() — same
## composition shape as UnitCombat/UnitMovement, unlike UnitStats
## (which never needs to reach into Unit at all).

var _owner: Unit
var _equipped: Dictionary = {}  # EquipSlot.Slot -> ItemInstance


func _init(owner: Unit) -> void:
	_owner = owner
	# ST sets Basic Lift and HT/DX set Move, so any stat change can move
	# the numbers; the encumbrance modifiers' own registration is skipped.
	owner.stat_changed.connect(func(_unit: Unit, _id: StringName) -> void: _update_encumbrance())


func get_item(slot_key: EquipSlot.Slot) -> ItemInstance:
	return _equipped.get(slot_key)


## The InjuryTraits every worn item grants (ItemDefinition.injury_traits).
func injury_traits() -> Array[InjuryTrait]:
	var out: Array[InjuryTrait] = []
	for item in _equipped.values():
		if item and item.definition:
			out.append_array(item.definition.injury_traits)
	return out


## Each hand slot's partner, main -> off.
const OFF_HAND_OF: Dictionary = {
	EquipSlot.Slot.MELEE_MAIN_HAND: EquipSlot.Slot.MELEE_OFF_HAND,
	EquipSlot.Slot.RANGED_MAIN_HAND: EquipSlot.Slot.RANGED_OFF_HAND,
}


## Whether item can go in slot_key given what the other hand holds: a
## two-handed weapon needs the off hand empty, and while one is held
## the off hand takes nothing. Refuses rather than moving the other
## hand's item, so nothing ever leaves a slot the player didn't touch.
func hands_allow(slot_key: EquipSlot.Slot, item: ItemInstance) -> bool:
	for main in OFF_HAND_OF:
		if OFF_HAND_OF[main] == slot_key:
			return not is_two_handed(get_item(main))
	if OFF_HAND_OF.has(slot_key) and is_two_handed(item):
		return get_item(OFF_HAND_OF[slot_key]) == null
	return true


static func is_two_handed(item: ItemInstance) -> bool:
	return item != null and item.gear_data != null and item.gear_data.weapon_data != null 		and item.gear_data.weapon_data.two_handed


## Every slot currently holding an item — used by PartyMemberData.capture()
## to enumerate a unit's loadout without needing to probe all 16 EquipSlot
## enum values by hand.
func equipped_slots() -> Array:
	return _equipped.keys()


## Records item as equipped in slot_key and registers every stat
## modifier it grants (ItemInstance.stat_modifiers: the definition's plus
## its runes') — does NOT touch the scene tree; showing it is EquipSlot's
## job, this is just the per-unit bookkeeping of what's currently worn.
## A rune socketed into it while worn re-registers (_refresh).
func equip(slot_key: EquipSlot.Slot, item: ItemInstance) -> void:
	_equipped[slot_key] = item
	_register(slot_key)
	_watchers[slot_key] = _refresh.bind(slot_key)
	item.modifiers_changed.connect(_watchers[slot_key])
	_update_encumbrance()


## Clears slot_key and reverts every stat modifier the previously-equipped
## item was granting. Returns the item that was there (or null), so the
## caller can decide where it goes next (a grid, another slot, ...).
func unequip(slot_key: EquipSlot.Slot) -> ItemInstance:
	var item: ItemInstance = _equipped.get(slot_key)
	if item:
		item.modifiers_changed.disconnect(_watchers[slot_key])
		_watchers.erase(slot_key)
		_unregister(slot_key)
	_equipped.erase(slot_key)
	_update_encumbrance()
	return item


## What each slot's item registered, so a changed item unregisters
## exactly what it had — not what it has now.
var _registered: Dictionary = {}  # EquipSlot.Slot -> Array[StatModifierBehavior]
var _watchers: Dictionary = {}  # EquipSlot.Slot -> the Callable on modifiers_changed


func _register(slot_key: EquipSlot.Slot) -> void:
	var item: ItemInstance = _equipped[slot_key]
	var granted: Array[StatModifierBehavior] = item.stat_modifiers()
	for modifier in granted:
		_owner.register_stat_modifier(modifier, item.display_name())
	_registered[slot_key] = granted


func _unregister(slot_key: EquipSlot.Slot) -> void:
	var item: ItemInstance = _equipped[slot_key]
	for modifier in _registered.get(slot_key, []):
		_owner.unregister_stat_modifier(modifier, item.display_name())
	_registered.erase(slot_key)


func _refresh(slot_key: EquipSlot.Slot) -> void:
	_unregister(slot_key)
	_register(slot_key)
	_owner.equipment_changed.emit(_owner)


## GURPS encumbrance (B17): the weight of worn and wielded gear against
## Basic Lift. Each level's ceiling in Basic Lifts, its name and its
## Move multiplier; a level's index is its Dodge penalty. The last
## ceiling is the most a unit can wear — weight_allows() refuses past it.
const ENCUMBRANCE_LEVELS: Array = [
	{"name": "None", "limit": 1.0, "move": 1.0},
	{"name": "Light", "limit": 2.0, "move": 0.8},
	{"name": "Medium", "limit": 3.0, "move": 0.6},
	{"name": "Heavy", "limit": 6.0, "move": 0.4},
	{"name": "Extra-Heavy", "limit": 10.0, "move": 0.2},
]


static func weight_of(item: ItemInstance) -> float:
	return item.gear_data.weight if item and item.gear_data else 0.0


func worn_weight() -> float:
	var total: float = 0.0
	for item in _equipped.values():
		total += weight_of(item)
	return total


## ST x ST / 5, rounded once it reaches 10 (B15). Read before Exhausted's
## halving: tiredness doesn't change what a body can lift.
func basic_lift() -> float:
	var st: float = _owner.get_stat_unhalved(StatIds.ST)
	var lift: float = st * st / 5.0
	return roundf(lift) if lift >= 10.0 else lift


## 0 (None) to 4 (Extra-Heavy). Gear can't be put on past the last
## level, but losing ST can carry a unit there; it stays Extra-Heavy.
func encumbrance_level() -> int:
	var weight: float = worn_weight()
	var lift: float = basic_lift()
	for level in ENCUMBRANCE_LEVELS.size():
		if weight <= lift * ENCUMBRANCE_LEVELS[level].limit:
			return level
	return ENCUMBRANCE_LEVELS.size() - 1


## Whether putting item in slot_key keeps worn weight within the last
## level. What's in the slot now comes off first; an item moving
## between this unit's slots isn't counted twice.
func weight_allows(slot_key: EquipSlot.Slot, item: ItemInstance) -> bool:
	var total: float = worn_weight()
	var held: ItemInstance = get_item(slot_key)
	if held and held != item:
		total -= weight_of(held)
	if not item in _equipped.values():
		total += weight_of(item)
	return total <= basic_lift() * ENCUMBRANCE_LEVELS[-1].limit


## The Dodge and Move modifiers the current level registers, under
## the source "<Level> encumbrance" so the sheet's breakdowns name it.
var _encumbrance_modifiers: Array[StatModifierBehavior] = []
var _encumbrance_source: String = ""
var _updating_encumbrance: bool = false


## Dodge takes the level as a penalty. Move is multiplied and rounded
## DOWN, min 1 (B17) — the stat system's multipliers round up, as a
## halving does — so it goes in as the flat difference, ahead of
## Exhausted's halving.
func _update_encumbrance() -> void:
	if _updating_encumbrance:
		return
	_updating_encumbrance = true
	var level: int = encumbrance_level()
	var move: int = floori(_owner.get_stat_unhalved(StatIds.MOVE))
	for modifier in _encumbrance_modifiers:
		if modifier.stat_name == StatIds.MOVE:
			move -= modifier.amount
	var move_change: int = 0
	if move >= 1:
		move_change = maxi(1, floori(move * ENCUMBRANCE_LEVELS[level].move)) - move
	var wanted: Dictionary = {StatIds.DODGE: -level, StatIds.MOVE: move_change}
	var source: String = "%s encumbrance" % ENCUMBRANCE_LEVELS[level].name
	var current: Dictionary = {StatIds.DODGE: 0, StatIds.MOVE: 0}
	for modifier in _encumbrance_modifiers:
		current[modifier.stat_name] = modifier.amount
	if wanted != current or (level > 0 and source != _encumbrance_source):
		for modifier in _encumbrance_modifiers:
			_owner.unregister_stat_modifier(modifier, _encumbrance_source)
		_encumbrance_modifiers.clear()
		_encumbrance_source = source
		for id in wanted:
			if wanted[id] != 0:
				var modifier := StatModifierBehavior.new()
				modifier.stat_name = id
				modifier.amount = wanted[id]
				_encumbrance_modifiers.append(modifier)
				_owner.register_stat_modifier(modifier, source)
	_updating_encumbrance = false
