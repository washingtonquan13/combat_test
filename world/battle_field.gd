class_name BattleField
extends GameArea
## Where an overworld random encounter is fought: the party arrives at
## PartySpawnPoint, the pending fight's enemies (OverworldEncounters.
## pending()) are spawned at the EnemySpawns markers, and the fight starts
## at once. Won, the party goes back to the overworld, to the spot it was
## caught. Owned by the overworld with the encounters themselves (see
## docs/systems/areas_bootstrap.md, "Random encounters").
##
## Arriving with nothing pending (a load of a save made here after the
## fight, say) sends the party straight back.

## Seconds between the last enemy falling and the trip back.
@export var return_delay: float = 2.0

var _encounter: Encounter


func _ready() -> void:
	WorldManager.world_focused.connect(_on_world_focused)
	CombatManager.encounter_finished.connect(_on_encounter_finished)


func _on_world_focused(world: Node) -> void:
	if world == self and _encounter == null:
		_begin.call_deferred()


func _begin() -> void:
	if not _start_pending():
		_leave()


## Spawns the pending fight's enemies and starts it; false with no fight
## pending or nobody here to fight it. The camp (camp.gd) starts its
## ambushes through this too.
func _start_pending() -> bool:
	var fight := OverworldEncounters.pending()
	var group: EncounterGroup = load(fight.group) if fight.has("group") and ResourceLoader.exists(fight.group) else null
	if group == null or group.units.is_empty():
		return false

	var party: Array[Unit] = []
	var context := WorldManager.context_for(self)
	for unit in PartyManager.members:
		if is_instance_valid(unit) and unit.is_alive() and context and context.contains(unit):
			party.append(unit)
	# Nobody here to fight it (a load into this area with the party
	# elsewhere): not a fight of the enemies alone.
	if party.is_empty():
		return false

	var spots: Array[Node] = get_node(^"EnemySpawns").get_children()
	var roster: Array[Unit] = party.duplicate()
	for i in group.units.size():
		var spot: Node3D = spots[i % spots.size()]
		# A second lap of the markers stands a little behind the first.
		var back := Vector3(0.0, 0.0, 2.0 * (i / spots.size()))
		roster.append(_spawn(group.units[i], spot.global_position + spot.global_basis * back))
	_encounter = CombatManager.start_combat(roster)
	return _encounter != null


func _spawn(definition: UnitDefinition, at: Vector3) -> Unit:
	var unit: Unit = definition.unit_scene.instantiate()
	# After .definition, whose cascade sets the species' own faction.
	unit.definition = definition
	unit.faction = &"enemy"
	unit.hover_color = Color(1, 0, 0, 0.501961)
	unit.selected_color = Color(1, 0, 0, 0.627451)
	add_child(unit)
	unit.global_position = at
	return unit


func _on_encounter_finished(encounter: Encounter, winning_faction: StringName) -> void:
	if encounter != _encounter:
		return
	_encounter = null
	# A wipe is the game over screen's; anything else, the party walks on.
	if winning_faction == &"enemy":
		return
	OverworldEncounters.finish_pending()
	_won()


## After a fight here is won: back to the overworld. The camp stays.
func _won() -> void:
	await get_tree().create_timer(return_delay).timeout
	if is_inside_tree() and WorldManager.current_world() == self:
		_leave()


func _leave() -> void:
	FlagManager.clear_flag(OverworldEncounters.PENDING_FLAG)
	WorldManager.travel_area(&"overworld")
