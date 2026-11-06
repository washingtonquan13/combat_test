extends GameArea
## The demo area: town edge, a road north, and the old quarry where the
## goblin raiders camp. Where a new game begins, and home of the Scared
## Townperson's raid quest.

var _goblinoids_remaining: Array[Unit] = []


func _ready() -> void:
	_watch_goblinoid_raid_quest()
	StartingParty.bootstrap(self, $PartySpawnPoint)


## Connected at scene start, not through the debug combat harness, so it
## fires however the fight starts. get_node_or_null(): a goblinoid killed
## on an earlier visit is freed by AreaState reconciliation before this
## runs, and once both are gone the flag is already set.
func _watch_goblinoid_raid_quest() -> void:
	var candidates: Array[Unit] = [
		get_node_or_null("GoblinRogue") as Unit,
		get_node_or_null("Hobgoblin") as Unit,
	]
	_goblinoids_remaining = candidates.filter(func(u): return is_instance_valid(u))
	for goblinoid in _goblinoids_remaining:
		goblinoid.died.connect(_on_goblinoid_died)


func _on_goblinoid_died(unit: Unit) -> void:
	_goblinoids_remaining.erase(unit)
	if _goblinoids_remaining.is_empty():
		FlagManager.set_flag("townsperson_raids_resolved")
