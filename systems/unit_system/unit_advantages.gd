class_name UnitAdvantages
extends RefCounted
## Which advantages this unit has and at what level. Each one puts a
## permanent status on the unit, built here from the advantage's behaviors
## at its level, so everything a status can do an advantage can do, and a
## stat tooltip names it like any other source. The status is hidden and
## never saved: this list is what saves, and the statuses are rebuilt from
## it (StatusManager.add_permanent).
##
## Built lazily by Unit, as UnitStats is: the definition setter writes
## advantages while the scene is still being instantiated, so a behavior's
## on_apply can run before the unit is in the tree.

var _owner: Unit
var _status_manager: StatusManager
var _container: Node
var _statuses: Dictionary = {}  # AdvantageInstance -> StatusEffect


func _init(owner: Unit, status_manager: StatusManager) -> void:
	_owner = owner
	_status_manager = status_manager
	_container = Node.new()
	_container.name = "Advantages"
	owner.add_child(_container)


func get_all() -> Array[AdvantageInstance]:
	var result: Array[AdvantageInstance] = []
	for child in _container.get_children():
		result.append(child as AdvantageInstance)
	return result


## 0 for an advantage this unit doesn't have.
func level_of(id: StringName) -> int:
	for instance in get_all():
		if instance.advantage.id == id:
			return instance.level
	return 0


## Clamped to the advantage's max_level; 0 takes it away.
func set_level(advantage: Advantage, level: int) -> void:
	var instance: AdvantageInstance = _find(advantage)
	var target: int = clampi(level, 0, advantage.max_level)
	if target == 0:
		if instance:
			_remove(instance)
		return
	if instance == null:
		instance = AdvantageInstance.new()
		instance.advantage = advantage
		_container.add_child(instance)
		for ability in advantage.abilities:
			if not _owner.abilities.has(ability):
				_owner.add_ability(ability)
	elif instance.level == target:
		return
	else:
		_status_manager.remove(_statuses[instance])
	instance.level = target
	_statuses[instance] = _build_status(advantage, target)
	_status_manager.add_permanent(_statuses[instance])


func clear() -> void:
	for instance in get_all():
		_remove(instance)


## advantage -> level, the shape UnitDefinition authors.
func add_all(levels: Dictionary) -> void:
	for advantage: Advantage in levels:
		set_level(advantage, levels[advantage])


## {id: level}. The only way advantages leave a unit.
func to_dict() -> Dictionary:
	var out: Dictionary = {}
	for instance in get_all():
		out[String(instance.advantage.id)] = instance.level
	return out


## Replaces the whole list. The only way saved advantages enter a unit.
func from_dict(data: Dictionary) -> void:
	clear()
	for id in data:
		var advantage: Advantage = AdvantageDatabase.find(StringName(id))
		if advantage:
			set_level(advantage, int(data[id]))
		else:
			push_warning("UnitAdvantages: unknown advantage '%s'" % id)


func _find(advantage: Advantage) -> AdvantageInstance:
	for instance in get_all():
		if instance.advantage == advantage:
			return instance
	return null


func _remove(instance: AdvantageInstance) -> void:
	_status_manager.remove(_statuses[instance])
	_statuses.erase(instance)
	for ability in instance.advantage.abilities:
		_owner.remove_ability(ability)
	instance.free()


func _build_status(advantage: Advantage, level: int) -> StatusEffect:
	var effect := StatusEffect.new()
	effect.status_name = advantage.advantage_name
	effect.curable = false
	for behavior in advantage.behaviors:
		effect.behaviors.append(behavior.at_level(level))
	return effect
