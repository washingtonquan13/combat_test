class_name StatInstance
extends Node
## One unit's own numbers for one stat — a child of the unit's Stats
## node, the same definition/instance split SkillInstance draws for
## skills. The StatDefinition says what the stat is; this says what THIS
## unit has of it. A Node, not a Resource, so two units can never end up
## sharing one by accident (the aliasing a duplicated .tres invites).
##
## Holds raw parts only, never the finished value: the value of a derived
## stat depends on other stats' instances, so UnitStats assembles it on
## every read (see StatDatabase.value_of).

## Emitted when anything here changes — base, a modifier, or a pool's
## current value. UnitStats turns it into Unit.stat_changed /
## Unit.pool_changed.
signal changed(instance: StatInstance)

var definition: StatDefinition

## PRIMARY: the stat itself before modifiers. DERIVED: a bought or sold
## bonus over the formula (see StatDefinition.Kind).
var base: int = 0:
	set(value):
		if base == value:
			return
		base = value
		changed.emit(self)

## Pools only — HP and FP today. Capped at the stat's value when set
## through UnitStats; never floored, since HP below 0 is a real state
## (Downed, down to -5 x HP).
var current: int = 0:
	set(value):
		if current == value:
			return
		current = value
		changed.emit(self)

## Statuses and gear currently changing this stat, each with its source.
var _modifiers: Array[ActiveStatModifier] = []


func _init(p_definition: StatDefinition = null) -> void:
	definition = p_definition
	if definition:
		name = String(definition.id)
		base = definition.default_value


func add_modifier(active: ActiveStatModifier) -> void:
	_modifiers.append(active)
	changed.emit(self)


## Removes the first registration of this exact modifier from this exact
## source — two statuses sharing one modifier resource stay independent.
func remove_modifier(modifier: StatModifierBehavior, source: String) -> bool:
	for i in _modifiers.size():
		if _modifiers[i].modifier == modifier and _modifiers[i].source == source:
			_modifiers.remove_at(i)
			changed.emit(self)
			return true
	return false


func modifier_total() -> int:
	var total: int = 0
	for active in _modifiers:
		total += active.modifier.amount
	return total


## Every multiplier on this stat, multiplied together — 1.0 with none.
## Two halvings are a quarter: each halves what the other left, and one
## rounding up of the product lands where rounding each halving would.
func modifier_multiplier() -> float:
	var product: float = 1.0
	for active in _modifiers:
		product *= active.modifier.multiplier
	return product


func active_modifiers() -> Array[ActiveStatModifier]:
	return _modifiers


func modifier_sources() -> Array[String]:
	var sources: Array[String] = []
	for active in _modifiers:
		sources.append(active.source)
	return sources
