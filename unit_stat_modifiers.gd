class_name UnitStatModifiers
extends RefCounted
## Owns the actual registry of currently active stat modifiers — the
## real state behind the "+ modifiers" half of Unit.get_stat(). Doesn't
## take an owner and never reaches into Unit at all, unlike UnitCombat/
## UnitMovement/etc. — it doesn't need to; a modifier is just data
## (StatModifierBehavior) and this only ever sums it.
##
## Deliberately independent of WHERE a modifier comes from.
## StatusManager.apply()/remove() register/unregister a
## StatModifierBehavior here when a status carrying one starts/ends, but
## this class has no idea statuses exist — a future equipment slot would
## register/unregister the exact same way on equip/unequip, with zero
## changes here. Same "producers push into one shared list, the
## consumer only ever reads the list" shape Unit.interactions/
## StatusEffect.behaviors already use for their own composition, just
## inverted: there the list is authored data; here it's runtime
## membership.

var _modifiers: Array[StatModifierBehavior] = []


func register_modifier(modifier: StatModifierBehavior) -> void:
	_modifiers.append(modifier)


func unregister_modifier(modifier: StatModifierBehavior) -> void:
	_modifiers.erase(modifier)


func stat_modifier(stat_name: String) -> int:
	var total: int = 0
	for modifier in _modifiers:
		if modifier.stat_name == stat_name:
			total += modifier.amount
	return total
