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

## The goblins' retaliation: the townsperson, told their raiders are dead,
## says the rest will come for the camp on the rise. The screen cuts to the
## camp at dusk, the raid plays, and the fight starts where it leaves off.
## Each step is a flag, so a save made anywhere in it resumes it.
const RAID_BEGUN := "goblin_raid.begun"
const RAID_PLAYED := "goblin_raid.raid_played"
const RAID_BROKEN := "goblin_raid.broken"
## The camp's north gate. Shut, it is two leaves with collision; broken, the
## leaves lie smashed inside and nothing stops a body.
const GATE_BROKEN := "goblin_quarry.gate_broken"
const RAID_STAGE: PackedScene = preload("res://cinematics/camp_raid.tscn")
const DUSK_ENVIRONMENT: Environment = preload("res://world/goblin_quarry/dusk_environment.tres")
## Where the party comes in, in the camp's own frame: on the slope beyond the
## south postern, where the stage's leader role starts.
const RAID_ARRIVAL := Vector3(0.0, -2.5, 24.0)
const RAID_FADE := 0.4
## The low evening sun the raid comes in, from the west-north-west.
const DUSK_SUN := Basis(Vector3(-0.43073, 0.0, 0.902481), Vector3(0.181332, 0.979606, 0.0865449),
		Vector3(-0.884076, 0.200926, -0.421945))
## The camp's people and the raiders, by role in the stage: node name here.
const RAID_CAST := {
	&"lookout": "Lookout", &"guard_gate": "GuardGate", &"guard_fire": "GuardFire",
	&"camper_fire": "CamperFire", &"camper_tent": "CamperTent", &"hobgoblin": "RaidHobgoblin",
	&"rogue_a": "RaidRogueA", &"rogue_b": "RaidRogueB", &"rogue_c": "RaidRogueC",
	&"rogue_d": "RaidRogueD", &"archer_west": "RaidArcherWest", &"archer_east": "RaidArcherEast",
}
## Who fights once the raid has played: the goblins, the armed camp and the
## party. The campers hide.
const RAID_FIGHTERS: Array[StringName] = [
	&"lookout", &"guard_gate", &"guard_fire", &"hobgoblin",
	&"rogue_a", &"rogue_b", &"rogue_c", &"rogue_d", &"archer_west", &"archer_east",
]
const RAIDERS: Array[StringName] = [
	&"hobgoblin", &"rogue_a", &"rogue_b", &"rogue_c", &"rogue_d", &"archer_west", &"archer_east",
]

var _goblinoids_remaining: Array[Unit] = []
## The raiders, out of the tree until the raid begins: not in the world, so
## nothing sees, hears or saves them, and the road below the camp is empty.
var _held_raiders: Array[Unit] = []
var _raiders_remaining: Array[Unit] = []
var _raid_staging := false
## Whether this visit's arrival has been dealt with. Until it has, the raid
## is what an arrival with the raid begun and unplayed is about to play.
var _arrival_settled := false


func _ready() -> void:
	_watch_goblinoid_raid_quest()
	_set_up_raid()
	$CampAmbushTrigger.body_entered.connect(_on_camp_ambush_entered)
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


func _set_up_raid() -> void:
	if FlagManager.has_flag(GATE_BROKEN):
		_show_broken()
	var begun := FlagManager.has_flag(RAID_BEGUN)
	if begun:
		_go_dusk()
	for role: StringName in RAIDERS:
		var raider := get_node_or_null(RAID_CAST[role]) as Unit
		if raider == null:
			continue  # Killed on an earlier visit, and freed by AreaState.
		raider.died.connect(_on_raider_died)
		_raiders_remaining.append(raider)
		if not begun:
			remove_child(raider)
			_held_raiders.append(raider)
	if begun and _raiders_remaining.is_empty() and not FlagManager.has_flag(RAID_BROKEN):
		FlagManager.set_flag(RAID_BROKEN)
	FlagManager.flag_changed.connect(_on_flag_changed)
	WorldManager.world_focused.connect(_on_world_focused)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for raider in _held_raiders:
			if is_instance_valid(raider):
				raider.free()
		_held_raiders.clear()


func _on_raider_died(unit: Unit) -> void:
	_raiders_remaining.erase(unit)
	if _raiders_remaining.is_empty():
		FlagManager.set_flag(RAID_BROKEN)


func _on_flag_changed(flag_name: String) -> void:
	if flag_name == RAID_BEGUN:
		_stage_raid()


## An arrival with the raid begun and unplayed (a save made between the
## turn-in and the scene) plays it.
func _on_world_focused(world: Node) -> void:
	if world != self:
		_arrival_settled = false
		return
	await get_tree().process_frame
	await get_tree().process_frame
	if FlagManager.has_flag(RAID_BEGUN) and not FlagManager.has_flag(RAID_PLAYED):
		_stage_raid()
	else:
		_arrival_settled = true


## The raid, while an arrival here is about to play it. Mid-visit the turn-in
## is not an arrival: the area's music plays on until the scene asks for its
## own, and the screen stays black while that loads.
func arrival_scene() -> PackedScene:
	if _arrival_settled or not FlagManager.has_flag(RAID_BEGUN) \
			or FlagManager.has_flag(RAID_PLAYED):
		return null
	return RAID_STAGE


## Waits out the conversation that began the raid, cuts to the camp at dusk
## with the party on the slope below the postern, plays the raid and starts
## the fight from where it leaves everyone. A precondition that fails returns
## before RAID_PLAYED is set, so a later arrival tries again; a cast member
## already dead means the camp the scene shows is gone, and the raiders
## simply come.
func _stage_raid() -> void:
	if _raid_staging or FlagManager.has_flag(RAID_PLAYED):
		return
	_raid_staging = true
	while GameMode.current_mode() != GameMode.Mode.EXPLORATION:
		await GameMode.mode_changed
	await get_tree().process_frame
	_arrival_settled = true
	var leader: Unit = PartyManager.leader
	if WorldManager.current_world() != self or FlagManager.has_flag(RAID_PLAYED) \
			or not is_instance_valid(leader) or not leader.is_alive() or leader.in_combat() \
			or not is_ancestor_of(leader):
		_raid_staging = false
		return

	var cover: Tween = ScreenFade.cover(RAID_FADE)
	if cover and cover.is_running():
		await cover.finished
	_go_dusk()
	_release_raiders()
	var party: Array[Unit] = [leader]
	var group := PartyManager.group_of(leader)
	if group:
		party = group.live_units()
	_place_party(leader, party)
	var units := _raid_units()
	if units.is_empty():
		ScreenFade.uncover(RAID_FADE)
		_raid_staging = false
		return
	var cast := SceneCast.new()
	for role: StringName in units:
		cast.track_unit(role, units[role])
	FlagManager.set_flag(RAID_PLAYED)
	_raid_staging = false

	_uncover_when_rolling()
	var finished: bool = await CinematicDirector.play(RAID_STAGE, cast)
	if ScreenFade.is_covered():
		ScreenFade.uncover(RAID_FADE)
	if not finished:
		return  # Aborted: the director released everything, something else owns the screen.
	var camera := CinematicDirector.camera()
	if camera:
		camera.release()

	var roster: Array[Unit] = []
	var fighters: Array = party.duplicate()
	for role in RAID_FIGHTERS:
		fighters.append(units[role])
	for unit in fighters:
		if is_instance_valid(unit) and unit.is_alive() and not unit.in_combat():
			roster.append(unit as Unit)
	CombatManager.start_combat(roster)


## The black lifts once the raid is rolling, not before: its first frame is
## held until the raid's music has loaded, and a held frame on screen reads
## as a hang.
func _uncover_when_rolling() -> void:
	await get_tree().process_frame
	while CinematicDirector.is_active():
		var stage := CinematicDirector.current_stage()
		if stage and stage.timeline() and stage.timeline().is_playing():
			break
		await get_tree().process_frame
	ScreenFade.uncover(RAID_FADE)


func _release_raiders() -> void:
	for raider in _held_raiders:
		if is_instance_valid(raider):
			add_child(raider)
	_held_raiders.clear()


func _place_party(leader: Unit, party: Array[Unit]) -> void:
	var arrival := Marker3D.new()
	add_child(arrival)
	arrival.global_transform = ($RaidCampOrigin as Node3D).global_transform \
			* Transform3D(Basis(Vector3.UP, PI), RAID_ARRIVAL)
	var followers: Array[Unit] = party.filter(func(u: Unit) -> bool: return u != leader)
	leader.stop_moving()
	PartyManager.place_at_landing(leader, arrival, -1, followers.size())
	for i in followers.size():
		followers[i].stop_moving()
		PartyManager.place_at_landing(followers[i], arrival, i, followers.size())
	arrival.queue_free()


## Evening, from the turn-in on: the light the raid comes in.
func _go_dusk() -> void:
	($WorldEnvironment as WorldEnvironment).environment = DUSK_ENVIRONMENT
	var sun := $DirectionalLight3D as DirectionalLight3D
	sun.basis = DUSK_SUN
	sun.light_color = Color(1.0, 0.64, 0.4)
	sun.light_energy = 1.7
	sun.light_volumetric_fog_energy = 1.6


## Role -> unit for the raid, the party leader as &"leader"; empty if any of
## them cannot play it.
func _raid_units() -> Dictionary:
	var leader: Unit = PartyManager.leader
	if not is_instance_valid(leader) or not leader.is_alive() or leader.in_combat() \
			or not leader.is_inside_tree():
		return {}
	var units: Dictionary = {&"leader": leader}
	for role: StringName in RAID_CAST:
		var unit := get_node_or_null(RAID_CAST[role]) as Unit
		if unit == null or not unit.is_alive() or unit.in_combat():
			return {}
		units[role] = unit
	return units


func gate_is_broken() -> bool:
	return FlagManager.has_flag(GATE_BROKEN)


## Smashes the gate in: remembered from now on, and the ground the leaves
## stood on is walkable at once. Called by the raid's AreaBeat.
func break_gate() -> void:
	FlagManager.set_flag(GATE_BROKEN)
	var was := smash_gate($LevelGeometry/RaidCamp/Gate)
	if was.has_volume():
		NavigationGrid.invalidate_region(self, was)


func _show_broken() -> void:
	smash_gate($LevelGeometry/RaidCamp/Gate)


## Swaps the camp gate's shut leaves for the smashed ones and returns the
## box the shut leaves blocked (empty if already smashed). The shut leaves
## are freed, not disabled: the nav grid scans disabled shapes too.
static func smash_gate(gate: Node3D) -> AABB:
	(gate.get_node("Broken") as Node3D).visible = true
	var shut := gate.get_node_or_null("Closed") as StaticBody3D
	if shut == null:
		return AABB()
	var box := AABB(shut.global_position, Vector3.ZERO)
	for child in shut.get_children():
		if child is CollisionShape3D and child.shape is BoxShape3D:
			var size: Vector3 = (child.shape as BoxShape3D).size
			box = box.merge(AABB(child.global_position - size * 0.5, size))
	gate.remove_child(shut)
	shut.queue_free()
	return box.grow(0.5)
