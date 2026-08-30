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

## Every group the party is currently divided into - see PartyGroup. One
## while the party is together, which is the ordinary case and the only
## one until somebody walks out of a door without the others.
var groups: Array[PartyGroup] = []

## The group the player is commanding. Everything that used to mean "the
## party" without qualification means THIS group now.
var active_group: PartyGroup = null

## Every live member across every group.
##
## Derived, not stored: the groups own their members, and a second copy
## kept in step by hand is the bug this exists to avoid. It reads exactly
## as it always did for a party that is together, which is why the eight
## or so places that consume it needed no changes at all.
##
## Because it BUILDS an array, mutating what it returns does nothing.
## Every writer goes through add_member/remove_member/clear_members,
## which target a group.
var members: Array[Unit]:
	get:
		var out: Array[Unit] = []
		for group in groups:
			for unit in group.units:
				if is_instance_valid(unit):
					out.append(unit)
		return out
var leader: Unit = null

## The party's PERSISTENT, canonical form — survives even a world that
## deliberately spawns no Units at all (see WorldManager.spawns_party()),
## like the overworld's single controllable avatar. members/leader are a
## live PROJECTION of this into real nodes for whichever world is
## currently spawning them; roster is what actually endures across a
## world swap. capture() writes here, spawn_party() reads from here.
## Same derivation as members, over the serializable form. capture() is
## what refreshes it against whatever is actually live; SaveManager reads
## it afterwards. Mutating what this returns does nothing - load_state()
## and capture() write through to the groups.
var roster: Array[PartyMemberData]:
	get:
		var out: Array[PartyMemberData] = []
		for group in groups:
			out.append_array(group.records)
		return out

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
# --- Groups ----------------------------------------------------------

## The group the player is commanding, made on demand. Everything that
## predates splitting lands here, so a game that never splits has exactly
## one group and behaves as it always did.
func active() -> PartyGroup:
	if active_group == null or not groups.has(active_group):
		active_group = PartyGroup.new()
		groups.append(active_group)
	return active_group


## The group holding this unit, or null.
func group_of(unit: Unit) -> PartyGroup:
	for group in groups:
		if group.has_unit(unit):
			return group
	return null


## Every group standing in an area. More than one only on the overworld,
## where each is drawn as its own avatar - in an ordinary area everyone
## is embodied together and there is nothing left to tell them apart, so
## arriving groups merge (see merge_in_area).
func groups_in_area(area_id: StringName) -> Array[PartyGroup]:
	var found: Array[PartyGroup] = []
	for group in groups:
		if group.area_id == area_id:
			found.append(group)
	return found


## Splits these travellers out of whatever groups hold them into a group
## of their own. THE operation the whole model exists for: the ones left
## behind keep their group and their place, and the ones going get a
## group that can be somewhere else.
##
## Returns the group they were already in when they are all of it - a
## whole group travelling together is not a split.
func split_off(travellers: Array[Unit]) -> PartyGroup:
	var going: Array[Unit] = []
	for unit in travellers:
		if is_instance_valid(unit) and is_member(unit):
			going.append(unit)
	if going.is_empty():
		return active()

	var origin: PartyGroup = group_of(going[0])
	if origin and origin.live_units().size() == going.size():
		var whole: bool = true
		for unit in going:
			if not origin.has_unit(unit):
				whole = false
				break
		if whole:
			return origin

	var split := PartyGroup.new()
	split.embodied = true
	split.area_id = origin.area_id if origin else &""
	for unit in going:
		var from_group: PartyGroup = group_of(unit)
		if from_group:
			from_group.units.erase(unit)
		split.units.append(unit)
	groups.append(split)
	prune_groups()
	return split


## Folds every group in an area into one. Called on arrival: once
## everyone is embodied in the same world there is no way to tell two
## groups apart, so keeping them separate would be bookkeeping with
## nothing behind it.
func merge_in_area(area_id: StringName) -> PartyGroup:
	var here: Array[PartyGroup] = groups_in_area(area_id)
	if here.is_empty():
		return null
	# An embodied group makes the better target: everyone ends up in the
	# form the area actually supports, rather than relying on absorb() to
	# correct the flag afterwards.
	var target: PartyGroup = here[0]
	for candidate in here:
		if candidate.embodied:
			target = candidate
			break
	for other in here:
		if other == target:
			continue
		target.absorb(other)
	if active_group in here:
		active_group = target
	prune_groups()
	return target


## Drops groups nobody is in any more. A group is a set of people, so an
## empty one is not a place - it is nothing.
func prune_groups() -> void:
	for group in groups.duplicate():
		if group.is_empty() and group != active_group:
			groups.erase(group)
	if active_group and active_group.is_empty() and groups.size() > 1:
		groups.erase(active_group)
		active_group = groups[0]


## Everyone in the party, in whichever form their group is currently
## in: live Units for an embodied group, records for an abstract one.
##
## Untyped on purpose — it is deliberately a mix, and which of the two
## a group contributes is a property of where that group is standing,
## not of the member. Anything that has to show or count THE WHOLE
## PARTY wants this rather than members or roster, both of which see
## only half of a split one.
func everyone() -> Array:
	var out: Array = []
	for group in groups:
		if group.embodied:
			for unit in group.live_units():
				out.append(unit)
		else:
			for record in group.records:
				out.append(record)
	return out


# --- Membership ------------------------------------------------------

func add_member(unit: Unit, into: PartyGroup = null) -> void:
	if not unit.is_player_controlled() or unit.summoned_by != null:
		push_warning("PartyManager.add_member refused: %s isn't a core party member." % unit.name)
		return
	if unit in members:
		return
	var group: PartyGroup = group_of(unit)
	if group == null:
		group = into if into else active()
		group.units.append(unit)
	group.embodied = true
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
	var group: PartyGroup = group_of(unit)
	if group:
		group.units.erase(unit)
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


## The leader's alignment regardless of which world is currently loaded —
## the live leader Unit if one is spawned (an ordinary area), otherwise
## the roster's own is_leader record (the overworld, which spawns no
## Units at all — see spawns_party()). Falls through to 0 (dead centre)
## only when there's genuinely no leader anywhere yet (before chargen).
## Read every frame by OverworldAvatar's alignment-driven spin, which is
## exactly the "need this outside a level" case members/leader alone
## can't answer.
func leader_alignment() -> int:
	if leader:
		return leader.alignment
	for record in roster:
		if record.is_leader:
			return record.alignment
	return 0


## Writes alignment to WHICHEVER of the live leader Unit / roster record
## currently exist, so a debug-set value holds across the next world
## transition either direction instead of being silently overwritten by
## capture()/spawn_party()'s own alignment fields. Not gated on
## OS.is_debug_build() here — that belongs to the caller (the debug
## panel); this is just a plain setter mirroring leader_alignment()'s own
## dual read path.
func set_leader_alignment(value: int) -> void:
	if leader:
		leader.alignment = value
	for record in roster:
		if record.is_leader:
			record.alignment = value


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
	# Per group, so a split party serializes as a split party rather than
	# as one flat list that has forgotten where anybody was.
	for group in groups:
		if not group.embodied:
			continue
		group.records.clear()
		for unit in group.live_units():
			group.records.append(_capture_one(unit))


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
	data.move_speed = unit.move_speed
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
	for group in groups:
		group.units.clear()
		group.embodied = false
	leader = null


## --- Save/load ---
## See SaveManager, the sole caller of both. Operates on roster, not
## members/leader directly — capture() (called first, below) is what
## keeps roster current against whatever's actually live right now, the
## same refresh a world transition already triggers.

## capture() first: roster is only ever refreshed on a world transition
## (see that method's own header), so without this a save taken mid-area
## would serialize STALE data — the roster as of the last transition, not
## this session's actual HP/equipment/position changes. Correctly a
## no-op in the overworld (capture()'s own members-empty guard), where
## roster is already the party's only representation.
func save_state() -> Dictionary:
	capture()
	var records: Array[Dictionary] = []
	for record in roster:
		records.append(_save_one(record))
	return {"members": records}


func _save_one(record: PartyMemberData) -> Dictionary:
	# "" for a null entry, not skipped — custom_slots in particular is a
	# fixed-size array of hotbar slots (see Unit.custom_slots's own
	# default: 6 nulls, meaning 6 empty slots), so which INDEX is empty
	# is real information; dropping null entries would shift every
	# later filled slot down on load. Same treatment for abilities for
	# consistency, even though nothing authors a null there today.
	var abilities: Array[String] = []
	for ability in record.abilities:
		abilities.append(ability.ability_name if ability else "")
	var custom_slots: Array[String] = []
	for ability in record.custom_slots:
		custom_slots.append(ability.ability_name if ability else "")

	var skills: Array[Dictionary] = []
	for skill_record in record.skills:
		skills.append({
			"skill_name": skill_record.skill.skill_name,
			"levels_purchased": skill_record.levels_purchased,
		})

	# Slot keys stay as their raw EquipSlot.Slot int — ConfigFile's Variant
	# round-trip preserves a Dictionary[int, String] exactly, so there's
	# no need to stringify the key the way JSON would have forced.
	var equipment: Dictionary = {}
	for slot in record.equipment:
		var gear: GearItem = record.equipment[slot]
		equipment[slot] = gear.id

	return {
		"definition_id": record.definition.id if record.definition else "",
		"is_leader": record.is_leader,
		"display_name": record.display_name,
		# The one unavoidable path-not-id exception — Texture2D has no id
		# field and no database (see SaveManager's own header on this).
		"portrait_path": record.portrait_texture.resource_path if record.portrait_texture else "",
		"faction": record.faction,
		"selected_color": record.selected_color,
		"hover_color": record.hover_color,
		"strength": record.strength,
		"dexterity": record.dexterity,
		"intelligence": record.intelligence,
		"health": record.health,
		"will": record.will,
		"perception": record.perception,
		"move": record.move,
		"move_speed": record.move_speed,
		"maximum_hp": record.maximum_hp,
		"current_hp": record.current_hp,
		"maximum_fp": record.maximum_fp,
		"current_fp": record.current_fp,
		"damage_reduction": record.damage_reduction,
		"alignment": record.alignment,
		"tendency": record.tendency,
		"abilities": abilities,
		"custom_slots": custom_slots,
		"skills": skills,
		"equipment": equipment,
	}


## Rebuilds roster from a save file — does NOT touch members/leader
## (still cleared from whatever WorldManager.unload() already did; see
## SaveManager's own load order). spawn_party() reads roster once the
## destination area actually exists, same as an ordinary world
## transition.
func load_state(state: Dictionary) -> void:
	# A save written before groups existed has one flat member list and no
	# group data at all. Loading it as a single group IS the migration -
	# and it is also exactly what a save of an unsplit party looks like, so
	# there is one path here rather than two.
	groups.clear()
	active_group = null
	var restored := PartyGroup.new()
	restored.area_id = state.get("area_id", &"")
	for entry in state.get("members", []):
		restored.records.append(_load_one(entry))
	groups.append(restored)
	active_group = restored


func _load_one(entry: Dictionary) -> PartyMemberData:
	var record := PartyMemberData.new()

	var definition_id: String = entry.get("definition_id", "")
	if definition_id != "":
		record.definition = SpawnableUnitDatabase.find(definition_id)

	record.is_leader = entry.get("is_leader", false)
	record.display_name = entry.get("display_name", "")

	var portrait_path: String = entry.get("portrait_path", "")
	if portrait_path != "":
		record.portrait_texture = load(portrait_path) as Texture2D

	record.faction = entry.get("faction", &"player")
	record.selected_color = entry.get("selected_color", record.selected_color)
	record.hover_color = entry.get("hover_color", record.hover_color)
	record.strength = entry.get("strength", record.strength)
	record.dexterity = entry.get("dexterity", record.dexterity)
	record.intelligence = entry.get("intelligence", record.intelligence)
	record.health = entry.get("health", record.health)
	record.will = entry.get("will", record.will)
	record.perception = entry.get("perception", record.perception)
	record.move = entry.get("move", record.move)
	record.move_speed = entry.get("move_speed", record.move_speed)
	record.maximum_hp = entry.get("maximum_hp", record.maximum_hp)
	record.current_hp = entry.get("current_hp", record.current_hp)
	record.maximum_fp = entry.get("maximum_fp", record.maximum_fp)
	record.current_fp = entry.get("current_fp", record.current_fp)
	record.damage_reduction = entry.get("damage_reduction", record.damage_reduction)
	record.alignment = entry.get("alignment", record.alignment)
	record.tendency = entry.get("tendency", record.tendency)

	# "" means the slot was empty at save time (see _save_one's own note
	# on custom_slots being fixed-size and index-meaningful) — append
	# null to preserve that position, not skip it. Only a NON-empty name
	# that fails to resolve is a real data problem worth a warning.
	for ability_name in entry.get("abilities", []):
		if ability_name == "":
			record.abilities.append(null)
			continue
		var ability: Ability = AbilityDatabase.find(ability_name)
		if ability:
			record.abilities.append(ability)
		else:
			push_warning("PartyManager.load_state: unknown ability '%s'" % ability_name)
			record.abilities.append(null)
	for ability_name in entry.get("custom_slots", []):
		if ability_name == "":
			record.custom_slots.append(null)
			continue
		var ability: Ability = AbilityDatabase.find(ability_name)
		if ability:
			record.custom_slots.append(ability)
		else:
			push_warning("PartyManager.load_state: unknown ability '%s'" % ability_name)
			record.custom_slots.append(null)

	for skill_entry in entry.get("skills", []):
		var skill: Skill = SkillDatabase.find(skill_entry.get("skill_name", ""))
		if not skill:
			continue
		var skill_record := PartySkillRecord.new()
		skill_record.skill = skill
		skill_record.levels_purchased = skill_entry.get("levels_purchased", 1)
		record.skills.append(skill_record)

	for slot in entry.get("equipment", {}):
		var gear: GearItem = ItemDatabase.find(entry["equipment"][slot]) as GearItem
		if gear:
			record.equipment[slot] = gear

	return record


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
	unit.move_speed = record.move_speed
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
		item.definition = record.equipment[slot]
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
## Kept as the whole-party form for any caller that means "the party"
## without qualification. Everything that travels goes through the
## group form below, because who is arriving is the question groups
## exist to answer.
func spawn_party(world: Node, spawn_point: Node3D) -> void:
	spawn_group(active(), world, spawn_point)


## Builds this group's records into live Units in `world`. The group
## becomes embodied; its records stay as the last serialized snapshot
## until capture() refreshes them.
func spawn_group(group: PartyGroup, world: Node, spawn_point: Node3D) -> void:
	var followers: Array[PartyMemberData] = []
	for record in group.records:
		if not record.is_leader:
			followers.append(record)

	group.units.clear()
	group.embodied = true
	for record in group.records:
		var unit: Unit = spawn_member(record, world, spawn_point)
		place_at_landing(unit, spawn_point,
			-1 if record.is_leader else followers.find(record), followers.size())
		group.units.append(unit)
		add_member(unit, group)
		if record.is_leader:
			set_leader(unit)


## Puts a unit down at the party's landing point. follower_index of -1
## means the leader, who lands exactly on the marker — it is the one
## position every door and spawn point was actually authored at. Everyone
## else takes a ring slot around it, snapped to a valid cell so raw trig
## can't drop them inside a wall or off a ledge.
##
## Shared by spawn_party (building units from roster) and relocate (moving
## units that already exist between worlds), so the two agree on where a
## party lands rather than each doing its own arithmetic.
func place_at_landing(unit: Unit, spawn_point: Node3D, follower_index: int, follower_count: int) -> void:
	unit.global_transform = spawn_point.global_transform
	if follower_index < 0 or follower_count <= 0:
		return

	var offset: Vector3 = FormationPlanner.ring_offset(
		follower_index, follower_count, unit.formation_spread_radius)
	var target: Vector3 = spawn_point.global_position + offset
	var clearance: float = unit.radius + unit.avoidance_margin
	# unit, not null: it is the one being placed, so it must not block its
	# own landing cell — and since the grid resolves which world a query
	# means from the unit it is handed (see NavigationGrid.activate_for),
	# passing it is also what aims this at the DESTINATION's grid rather
	# than whichever world happened to be active.
	var resolved: Dictionary = NavigationGrid.nearest_valid_point(
		get_tree(), target, clearance, false, unit)
	if resolved.found:
		unit.global_position = resolved.point


## Moves party members that are ALREADY EMBODIED from whatever world they
## are in into `world`, landing them like a fresh spawn.
##
## This is what travel does now, instead of capture-into-roster and
## rebuild-from-roster on the other side. That round trip was lossy by
## construction — _capture_one copies a fixed list of fields, so anything
## added to Unit and not to that list silently vanished on every area
## transition — and it could only ever move the party as a whole, since
## roster has no notion of who is going. Reparenting carries the real
## thing: buffs, in-flight state, equipment, everything.
##
## Rungs 2 and 3a are what make this work rather than merely compile:
## every query, AI check, detection sweep and navigation query derives its
## world from the unit's own get_world_3d(), so a unit that changes parent
## is simply, immediately, in the other world.
func relocate(units: Array[Unit], world: Node, spawn_point: Node3D) -> void:
	var movers: Array[Unit] = []
	for unit in units:
		if is_instance_valid(unit) and unit.is_inside_tree():
			movers.append(unit)
	if movers.is_empty() or not is_instance_valid(world) or spawn_point == null:
		return

	# Leader first, so the ring is built around whoever holds the marker.
	movers.sort_custom(func(a: Unit, b: Unit) -> bool:
		return is_leader(a) and not is_leader(b))

	var has_leader: bool = is_leader(movers[0])
	var follower_count: int = movers.size() - (1 if has_leader else 0)
	var follower_index: int = 0

	for unit in movers:
		# A half-finished walk carries a destination in the OLD world's
		# coordinates and a path through its navigation grid. Neither
		# means anything here.
		unit.force_stop_movement()
		unit.reparent(world, false)

		if is_leader(unit):
			place_at_landing(unit, spawn_point, -1, follower_count)
		else:
			place_at_landing(unit, spawn_point, follower_index, follower_count)
			follower_index += 1
