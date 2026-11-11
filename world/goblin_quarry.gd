extends GameArea
## The demo area: town edge, a road north, and the old quarry where the
## goblin raiders camp. Where a new game begins, and home of the Scared
## Townperson's raid quest.

## The camp ambush: the goblins come out to meet the party at the corridor
## mouth, the Town Watchman arrives behind them, and the fight starts when
## the scene ends. Plays once; see _on_camp_ambush_entered.
const CAMP_AMBUSH_STAGE: PackedScene = preload("res://cinematics/goblin_camp_ambush.tscn")
const CAMP_AMBUSH_FLAG := "goblin_camp.ambush_played"
## Party members this close to whoever walked in are part of the scene and
## the fight. Matches the latecomer hearing radius, so anyone farther would
## not have joined the fight on their own either.
const CAMP_AMBUSH_PARTY_RADIUS: float = 22.0
const CAMP_AMBUSH_NPCS: Array[String] = ["Hobgoblin", "GoblinRogue", "GoblinShaman", "Watchman"]

var _goblinoids_remaining: Array[Unit] = []


func _ready() -> void:
	_watch_goblinoid_raid_quest()
	$CampAmbushTrigger.body_entered.connect(_on_camp_ambush_entered)
	var trample := GrassTrample.new()
	trample.name = "GrassTrample"
	trample.grass = $LevelGeometry/Terrain/Grass
	add_child(trample)
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


## Every precondition failure returns BEFORE the flag is set, so a party
## that was spotted first (fight already running) or walked in mid-scene
## gets the cutscene on a later entry instead of losing it. A camp goblin
## already dead means the camp the scene shows no longer exists: no scene,
## ever, and the goblins fight wherever they are found.
func _on_camp_ambush_entered(body: Node3D) -> void:
	if not (body is Unit and body.is_player_controlled()):
		return
	if FlagManager.has_flag(CAMP_AMBUSH_FLAG):
		return
	if GameMode.current_mode() != GameMode.Mode.EXPLORATION:
		return
	var leader := body as Unit
	if leader.in_combat():
		return
	var npcs: Dictionary = {}
	for node_name in CAMP_AMBUSH_NPCS:
		var npc := get_node_or_null(node_name) as Unit
		if npc == null or not npc.is_alive() or npc.in_combat():
			return
		npcs[node_name] = npc
	FlagManager.set_flag(CAMP_AMBUSH_FLAG)

	var party: Array[Unit] = []
	var group := PartyManager.group_of(leader)
	var members: Array[Unit] = [leader]
	if group:
		members = group.live_units()
	for member in members:
		if member.is_alive() and not member.in_combat() \
				and member.global_position.distance_to(leader.global_position) <= CAMP_AMBUSH_PARTY_RADIUS:
			member.stop_moving()
			party.append(member)

	var cast := SceneCast.new().track_unit(&"leader", leader)
	cast.track_unit(&"hobgoblin", npcs["Hobgoblin"])
	cast.track_unit(&"rogue", npcs["GoblinRogue"])
	cast.track_unit(&"shaman", npcs["GoblinShaman"])
	cast.track_unit(&"watchman", npcs["Watchman"])
	var finished: bool = await CinematicDirector.play(CAMP_AMBUSH_STAGE, cast)
	if not finished:
		return  # Aborted: the director released everything, something else owns the screen.
	var camera := CinematicDirector.camera()
	if camera:
		camera.release()

	var roster: Array[Unit] = []
	for unit in party + npcs.values():
		if is_instance_valid(unit) and unit.is_alive() and not unit.in_combat():
			roster.append(unit as Unit)
	CombatManager.start_combat(roster)
