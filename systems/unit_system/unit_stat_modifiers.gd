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
##
## Tracks ActiveStatModifier wrappers, not bare StatModifierBehaviors —
## see that file's header for why source can't live on the shared
## behavior resource itself.

var _active: Array[ActiveStatModifier] = []


func register_modifier(modifier: StatModifierBehavior, source: String) -> void:
	_active.append(ActiveStatModifier.new(modifier, source))


## Removes the first registration matching this exact modifier object.
## Fine for today's only caller (StatusManager always registers and
## unregisters the same StatModifierBehavior instance once each), but if
## a modifier object is ever registered more than once concurrently —
## the same shared behavior applied from two different sources at once,
## say — this can't tell which application to remove and just takes the
## first. Not a real risk yet (nothing does that today), but worth
## knowing before assuming this scales to arbitrary concurrent sources.
func unregister_modifier(modifier: StatModifierBehavior) -> void:
	for active_modifier in _active:
		if active_modifier.modifier == modifier:
			_active.erase(active_modifier)
			return


func stat_modifier(stat_name: String) -> int:
	var total: int = 0
	for active_modifier in _active:
		if active_modifier.modifier.stat_name == stat_name:
			total += active_modifier.modifier.amount
	return total


## Every currently active contribution to a named stat, source included —
## for a future tooltip ("DR 5: +3 Shield, +2 base") rather than just
## the summed total stat_modifier() gives.
func stat_modifier_sources(stat_name: String) -> Array[ActiveStatModifier]:
	var result: Array[ActiveStatModifier] = []
	for active_modifier in _active:
		if active_modifier.modifier.stat_name == stat_name:
			result.append(active_modifier)
	return result
