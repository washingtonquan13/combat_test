extends Node
## Autoload singleton. Register as "PartyManager" under
## Project > Project Settings > AutoLoad.
##
## The party's own real membership — an explicit, authoritative roster,
## not a derived scene-tree query. UnitQuery.core_party_units() (the
## live "units" group filtered by is_player_controlled()/summoned_by)
## still exists and still works unchanged for every EXISTING consumer —
## this is deliberately additive, not a migration. But anything NEW that
## needs to ask "who's actually in my party" should ask THIS, not
## re-derive the same filter: a live scene query can't answer that
## question once a unit might exist without being placed in the current
## scene at all (a future character-creation flow, a debug add/remove
## menu, eventual save/load) — exactly the "stop relying on hardcoded
## party members" gap this exists to start closing.
##
## Also owns which single member, if any, is currently designated the
## player character / party leader — distinguishing "the protagonist"
## from an ordinary party member for the first time in this project.
##
## leader/members hold live Unit references, same shape as
## Unit.summoned_by/owned_demon — "who's in the party right now" is a
## question about live nodes. What fully DESCRIBES a party member as data
## is a separate, cleanly separable question, answered by PartyMemberData
## (see that file) — capture()/clear_members()/spawn_party() below are the
## bridge between the two, and are what make WorldManager's replace-only
## world loading possible without losing the party.

const ITEM_SCENE: PackedScene = preload("res://systems/inventory_system/item.tscn")
const UNIT_SCENE: PackedScene = preload("res://unit.tscn")

signal member_added(unit: Unit)
signal member_removed(unit: Unit)
signal leader_changed(unit: Unit)

var members: Array[Unit] = []
var leader: Unit = null

## The party's PERSISTENT, canonical form — survives even a world that
## deliberately spawns no Units at all (see WorldManager.spawns_party()),
## like the overworld's single controllable avatar. members/leader are a
## live PROJECTION of this into real nodes for whichever world is
## currently spawning them; roster is what actually endures across a
## world swap. capture() writes here, spawn_party() reads from here.
var roster: Array[PartyMemberData] = []

## Set by character_creation.gd on Confirm, consumed once by whichever
## world first spawns it (today: test_arena.gd's own _build_leader();
## once WorldManager exists, its first load_world() call) — the same
## "can't build a real Unit until a world exists to place it in" bridge
## the old PendingCharacter autoload used to serve, just carrying a real
## PartyMemberData instead of a parallel set of loose ad hoc fields.
var pending_leader: PartyMemberData = null


## Silently refused (with a warning) for anything that isn't a core party
## unit — mirrors the exact guard SelectionManager.select() already
## applies for "can this unit ever be treated as ours at all." Idempotent
## — adding an already-present member is a safe no-op, same convention
## SummonDemonEffect/DemonRoster already use elsewhere.
func add_member(unit: Unit) -> void:
	if not unit.is_player_controlled() or unit.summoned_by != null:
		push_warning("PartyManager.add_member refused: %s isn't a core party member." % unit.name)
		return
	if unit in members:
		return
	members.append(unit)
	unit.died.connect(_on_member_died)
	member_added.emit(unit)


## Removes the roster ENTRY only — does not touch the live Unit node or
## the scene tree at all. Deliberately separate concerns: whether a
## dismissed/removed party member's node should be freed, hidden, or
## left standing in the world is a decision for whatever future feature
## actually calls this (the debug add/remove menu, e.g.), not something
## this file should assume. Clears leader too if the removed unit WAS
## the leader — you can't lead a party you're not in.
func remove_member(unit: Unit) -> void:
	if unit not in members:
		return
	members.erase(unit)
	if unit.died.is_connected(_on_member_died):
		unit.died.disconnect(_on_member_died)
	if leader == unit:
		leader = null
		leader_changed.emit(null)
	member_removed.emit(unit)


func _on_member_died(unit: Unit) -> void:
	remove_member(unit)


func is_member(unit: Unit) -> bool:
	return unit in members


## Must already be a member — leader is a role WITHIN the roster, not an
## independent designation with its own separate validity check.
func set_leader(unit: Unit) -> void:
	if not is_member(unit):
		push_warning("PartyManager.set_leader refused: %s isn't a party member." % unit.name)
		return
	if leader == unit:
		return
	leader = unit
	leader_changed.emit(unit)


func is_leader(unit: Unit) -> bool:
	return unit != null and unit == leader


## --- World reload (capture/spawn) ---
## The pair that makes replace-only world loading possible without losing
## the party — see WorldManager.load_world(), the sole caller of both
## halves. Sequencing matters: clear_members() must run WHILE the outgoing
## Units are still valid (before the old world is freed); spawn_party()
## runs once the new world exists. Neither half is safe to call out of
## that order.

## Snapshots every current party member into roster — see
## PartyMemberData's own header for exactly what is and isn't captured.
## Must be called before clear_members()/the old world being freed, since
## it reads directly off the live Unit nodes.
##
## Guarded on members not being empty: leaving a world that never spawned
## the party in the first place (the overworld, e.g. — see
## WorldManager.spawns_party()) would otherwise silently overwrite
## roster with an empty capture and lose the party for real. members
## being empty there is expected, not "the party left" — roster already
## correctly remembers who's actually in it from the last world that DID
## spawn them.
func capture() -> void:
	if members.is_empty():
		return
	roster.clear()
	for unit in members:
		roster.append(_capture_one(unit))


func _capture_one(unit: Unit) -> PartyMemberData:
	var data := PartyMemberData.new()
	data.definition = unit.definition
	data.display_name = unit.display_name
	data.portrait_texture = unit.portrait_texture
	data.faction = unit.faction
	data.strength = unit.strength
	data.dexterity = unit.dexterity
	data.intelligence = unit.intelligence
	data.health = unit.health
	data.will = unit.will
	data.perception = unit.perception
	data.move = unit.move
	data.maximum_hp = unit.maximum_hp
	data.current_hp = unit.current_hp
	data.maximum_fp = unit.maximum_fp
	data.current_fp = unit.current_fp
	data.damage_reduction = unit.damage_reduction
	data.alignment = unit.alignment
	data.tendency = unit.tendency
	data.abilities = unit.abilities.duplicate()
	data.custom_slots = unit.custom_slots.duplicate()
	data.is_leader = is_leader(unit)
	data.selected_color = unit.selected_color
	data.hover_color = unit.hover_color

	for skill_instance in unit.get_skills():
		var record := PartySkillRecord.new()
		record.skill = skill_instance.skill_data
		record.levels_purchased = skill_instance.levels_purchased
		data.skills.append(record)

	for slot in unit.get_equipped_slots():
		var item: Item = unit.get_equipped_item(slot)
		if item and item.gear_data:
			data.equipment[slot] = item.gear_data

	return data


## Disconnects every current member's died signal and empties the roster
## — the "let go of the old roster" half of a world reload, called while
## the outgoing Units are still valid enough to safely disconnect from
## (right before WorldManager frees the world housing them). Deliberately
## does not emit member_removed/leader_changed: nothing needs to react to
## an incremental teardown here, since every listener is about to see a
## whole new world via WorldManager's own world_loaded signal instead.
func clear_members() -> void:
	for unit in members:
		if is_instance_valid(unit) and unit.died.is_connected(_on_member_died):
			unit.died.disconnect(_on_member_died)
	members.clear()
	leader = null


## Instantiates one party member from a snapshot and places it in world —
## definition.unit_scene if the record carries a species (a recruited
## demon or authored companion), plain unit.tscn otherwise (a character-
## creation leader has no species template at all). Assigning definition
## first, when present, fires Unit's own cascading setter before every
## recorded field is written on top of it — the same cascade-then-
## override order Unit.definition's own setter documents, so anything
## individually progressed (current_hp after damage, a trained skill)
## always wins over the species baseline it started from.
func spawn_member(record: PartyMemberData, world: Node, spawn_point: Node3D) -> Unit:
	var scene: PackedScene = UNIT_SCENE
	if record.definition and record.definition.unit_scene:
		scene = record.definition.unit_scene

	var unit: Unit = scene.instantiate()
	world.add_child(unit)
	unit.global_transform = spawn_point.global_transform

	if record.definition:
		unit.definition = record.definition

	unit.display_name = record.display_name
	unit.portrait_texture = record.portrait_texture
	unit.faction = record.faction
	unit.strength = record.strength
	unit.dexterity = record.dexterity
	unit.intelligence = record.intelligence
	unit.health = record.health
	unit.will = record.will
	unit.perception = record.perception
	unit.move = record.move
	unit.maximum_hp = record.maximum_hp
	unit.current_hp = record.current_hp
	unit.maximum_fp = record.maximum_fp
	unit.current_fp = record.current_fp
	unit.damage_reduction = record.damage_reduction
	unit.alignment = record.alignment
	unit.tendency = record.tendency
	unit.abilities = record.abilities.duplicate()
	unit.custom_slots = record.custom_slots.duplicate()
	unit.selected_color = record.selected_color
	unit.hover_color = record.hover_color

	for skill_record in record.skills:
		var instance := SkillInstance.new()
		instance.skill_data = skill_record.skill
		instance.levels_purchased = skill_record.levels_purchased
		world.add_child(instance)  # needs a parent before add_skill's reparent() call
		unit.add_skill(instance)

	for slot in record.equipment:
		var item: Item = ITEM_SCENE.instantiate()
		item.gear_data = record.equipment[slot]
		unit.equip_item(slot, item)

	return unit


## Spawns every roster record into world and rebuilds members/leader
## against the freshly-instantiated Units — the counterpart to capture().
## Must run after clear_members() (old roster already let go) and after
## world actually exists in the tree.
##
## Every record lands at spawn_point first (spawn_member's own existing
## contract — test_arena.gd's chargen-leader bootstrap call relies on
## that exact single-point behavior too, so it's left unchanged). Every
## NON-leader record is then nudged onto FormationPlanner's own ring
## offset around that same point and snapped to the nearest real standing
## cell via NavigationGrid.nearest_valid_point() — without the offset,
## every member spawns exactly coincident (a real shipped bug: the
## physics solver's depenetration shoves some of them airborne, and
## before unit_movement.gd's own gravity fix they'd stay there forever,
## with no support cell for NavigationGrid to path across); without the
## snap, raw trig can land a follower inside a wall or off a ledge just
## as easily as on solid ground. The leader keeps the party's true
## landing point exactly, unmoved — it's the one position every door/
## spawn marker was actually authored at.
func spawn_party(world: Node, spawn_point: Node3D) -> void:
	var followers: Array[PartyMemberData] = []
	for record in roster:
		if not record.is_leader:
			followers.append(record)

	for record in roster:
		var unit: Unit = spawn_member(record, world, spawn_point)

		if not record.is_leader:
			var index: int = followers.find(record)
			var offset: Vector3 = FormationPlanner.ring_offset(index, followers.size(), unit.formation_spread_radius)
			var target: Vector3 = spawn_point.global_position + offset
			var clearance: float = unit.radius + unit.avoidance_margin
			var resolved: Dictionary = NavigationGrid.nearest_valid_point(get_tree(), target, clearance, false, null)
			if resolved.found:
				unit.global_position = resolved.point

		add_member(unit)
		if record.is_leader:
			set_leader(unit)
