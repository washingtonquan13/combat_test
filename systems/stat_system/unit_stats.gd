class_name UnitStats
extends RefCounted
## Owns this unit's stats — one StatInstance child of a Stats node for
## every stat StatDatabase knows, so a stat added as a .tres exists on
## every unit with its default, no code touched. Built like UnitSkills:
## a private component behind Unit's own forwarders (get_stat, pool
## reads and writes, modifier registration), never reached into from
## outside.
##
## The Stats node is created here, in code, not authored in unit.tscn:
## Unit's definition setter runs while the scene is still being
## instantiated, BEFORE the scene's own children exist, and it has to
## write stats. So Unit builds this lazily on first use and the node
## comes with it.
##
## to_dict()/from_dict() are the only way stats leave or enter a unit —
## saves, the party snapshot, the summon round trip all go through them,
## so a new stat is saved without anyone listing it.

## The stat's own parts changed (base, a modifier, a pool's current).
## Derived stats that read it changed too; listeners that show those
## recompute on this.
signal stat_changed(id: StringName)
signal pool_changed(id: StringName, current: int, maximum: int)

var _container: Node
var _instances: Dictionary = {}  # StringName -> StatInstance


func _init(owner: Node) -> void:
	_container = Node.new()
	_container.name = "Stats"
	owner.add_child(_container)
	for definition in StatDatabase.get_all():
		var instance := StatInstance.new(definition)
		_container.add_child(instance)
		_instances[definition.id] = instance
		instance.changed.connect(_on_instance_changed)
	fill_pools()


## The stat's value with everything applied — formula, bonus, statuses,
## gear. 0 (with an error) for an id no stat file declares.
func get_value(id: StringName) -> float:
	return StatDatabase.value_of(id, _base_of, _modifier_of, _multiplier_of)


## The value before any multiplier — flat modifiers in, halvings out.
## What ST-based quantities read: Exhausted halves ST, but not the
## damage it deals (B426).
func get_unhalved(id: StringName) -> float:
	return StatDatabase.value_of(id, _base_of, _modifier_of)


## Unmodified base — a primary's authored value, a derived stat's bonus.
func get_base(id: StringName) -> int:
	var instance := _instance(id)
	return instance.base if instance else 0


func set_base(id: StringName, value: int) -> void:
	var instance := _instance(id)
	if instance:
		instance.base = value


## The value with nothing applied: what the stat is before any status or
## gear — the character sheet's "base" column, the chargen preview.
func get_unmodified(id: StringName) -> float:
	return StatDatabase.value_of(id, _base_of, func(_id: StringName) -> int: return 0)


func get_current(id: StringName) -> int:
	var instance := _pool(id)
	return instance.current if instance else 0


## Sets a pool, capped at its maximum. Not floored: HP below 0 is a state.
func set_current(id: StringName, value: int) -> void:
	var instance := _pool(id)
	if instance:
		instance.current = mini(value, floori(get_value(id)))


func damage(id: StringName, amount: int) -> void:
	set_current(id, get_current(id) - amount)


func restore(id: StringName, amount: int) -> void:
	set_current(id, get_current(id) + amount)


## Every stat to these bases (id -> int), every stat they leave out to
## its default, every pool full — what assigning a UnitDefinition does.
## Not a merge, unlike from_dict: a unit re-assigned a species must not
## keep the old one's ST.
func reset(bases: Dictionary) -> void:
	for id in _instances:
		var instance: StatInstance = _instances[id]
		instance.base = int(bases.get(id, instance.definition.default_value))
	fill_pools()


## Every pool back to full — a fresh unit, a new definition.
func fill_pools() -> void:
	for id in _instances:
		var instance: StatInstance = _instances[id]
		if instance.definition.is_pool:
			instance.current = floori(get_value(id))


func add_modifier(modifier: StatModifierBehavior, source: String) -> void:
	var instance := _instance(modifier.stat_name)
	if instance:
		instance.add_modifier(ActiveStatModifier.new(modifier, source))


func remove_modifier(modifier: StatModifierBehavior, source: String) -> void:
	var instance := _instance(modifier.stat_name)
	if instance:
		instance.remove_modifier(modifier, source)


func modifier_total(id: StringName) -> int:
	var instance := _instance(id)
	return instance.modifier_total() if instance else 0


func modifier_sources(id: StringName) -> Array[String]:
	var instance := _instance(id)
	return instance.modifier_sources() if instance else ([] as Array[String])


## {"stats": {id: base}, "pools": {id: current}} — bases of every stat,
## currents of every pool. Modifiers are not saved: statuses and gear
## re-register their own when they are restored.
func to_dict() -> Dictionary:
	var stats: Dictionary = {}
	var pools: Dictionary = {}
	for id in _instances:
		var instance: StatInstance = _instances[id]
		stats[String(id)] = instance.base
		if instance.definition.is_pool:
			pools[String(id)] = instance.current
	return {"stats": stats, "pools": pools}


## Merges only what is present: a dict with just "pools" (a summon's
## carried-over HP) leaves the bases alone, and a stat the dict does not
## know keeps its default. Bases go first so the pools' caps are right.
## Keys a save names that no stat file declares are skipped — a stat
## removed from data/stats/ must not break old saves.
func from_dict(data: Dictionary) -> void:
	for key in data.get("stats", {}):
		set_base(StringName(key), int(data.stats[key]))
	for key in data.get("pools", {}):
		set_current(StringName(key), int(data.pools[key]))


func _instance(id: StringName) -> StatInstance:
	var instance: StatInstance = _instances.get(id)
	if instance == null:
		push_error("No stat '%s' — see res://data/stats/." % id)
	return instance


func _pool(id: StringName) -> StatInstance:
	var instance := _instance(id)
	if instance and not instance.definition.is_pool:
		push_error("Stat '%s' is not a pool." % id)
		return null
	return instance


func _base_of(id: StringName) -> int:
	var instance: StatInstance = _instances.get(id)
	return instance.base if instance else 0


func _modifier_of(id: StringName) -> int:
	var instance: StatInstance = _instances.get(id)
	return instance.modifier_total() if instance else 0


func _multiplier_of(id: StringName) -> float:
	var instance: StatInstance = _instances.get(id)
	return instance.modifier_multiplier() if instance else 1.0


func _on_instance_changed(instance: StatInstance) -> void:
	var id: StringName = instance.definition.id
	stat_changed.emit(id)
	for pool_id in _instances:
		var pool: StatInstance = _instances[pool_id]
		if pool.definition.is_pool:
			pool_changed.emit(pool_id, pool.current, floori(get_value(pool_id)))
