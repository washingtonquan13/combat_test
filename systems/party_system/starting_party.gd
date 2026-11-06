class_name StartingParty
extends RefCounted
## The one-time starting-party bootstrap: one character, the leader chargen
## produced (or the authored wizard when chargen never ran), built at an
## area's PartySpawnPoint. Shared by every area a game can begin in, so
## the starting area can change without copying this.
##
## The demo hands that one character everything: every ability in
## res://data/abilities, a worn loadout, and every other item in the bag.
## Both are read from the folders, so a new spell or item is picked up
## without listing it here.
##
## Does nothing once PartyManager holds anyone: a reload or a re-entry
## restores the captured roster instead.

const FALLBACK_LEADER := "res://data/units/companions/tiefling_wizard.tres"
const ABILITY_DIR := "res://data/abilities/"
const ITEM_DIR := "res://data/items/"
## Every unit gets these whatever it lists (UnitCombat's innate set), so
## listing them as well would show them twice.
const INNATE_ABILITIES: Array[String] = [
	"pick_up", "target_head", "target_vitals", "deceptive_attack", "reload",
]
## What the character starts wearing. Everything else goes in the bag.
const WORN := {
	EquipSlot.Slot.HELMET: "leather_helmet",
	EquipSlot.Slot.CHEST_ARMOR: "leather_chestpiece",
	EquipSlot.Slot.GLOVES: "leather_gloves",
	EquipSlot.Slot.BELT: "leather_belt",
	EquipSlot.Slot.BOOTS: "leather_boots",
	EquipSlot.Slot.MELEE_MAIN_HAND: "iron_sword",
	EquipSlot.Slot.MELEE_OFF_HAND: "wooden_shield",
	EquipSlot.Slot.RANGED_MAIN_HAND: "longbow",
}


static func bootstrap(area: Node3D, spawn_point: Node3D) -> void:
	if not PartyManager.members.is_empty() or not PartyManager.roster.is_empty():
		return
	var leader: Unit = _build_leader(area, spawn_point)
	_give_everything(leader)
	PartyManager.add_member(leader)
	PartyManager.set_leader(leader)


## The character chargen produced if there is one, and the authored wizard
## otherwise (a headless test loading straight into an area never runs
## chargen).
static func _build_leader(area: Node3D, spawn_point: Node3D) -> Unit:
	if PartyManager.pending_leader:
		var made: Unit = PartyManager.spawn_member(PartyManager.pending_leader, area, spawn_point)
		PartyManager.pending_leader = null
		return made
	var definition: UnitDefinition = load(FALLBACK_LEADER)
	var unit: Unit = definition.unit_scene.instantiate()
	# BEFORE add_child: Unit._enter_tree adopts the body a definition names.
	unit.definition = definition
	# Stamped from the definition's id rather than minted at first capture,
	# so two units can never answer to the same id.
	unit.persistent_id = StringName("companion_%s" % definition.id)
	area.add_child(unit)
	unit.position = spawn_point.position
	return unit


static func _give_everything(leader: Unit) -> void:
	var abilities: Array[Ability] = []
	for id in _resource_ids(ABILITY_DIR):
		if not INNATE_ABILITIES.has(id):
			abilities.append(load(ABILITY_DIR + id + ".tres"))
	leader.set_abilities(abilities)

	for id in _resource_ids(ITEM_DIR):
		var definition: ItemDefinition = load(ITEM_DIR + id + ".tres")
		var item := ItemInstance.new(definition)
		var slot = WORN.find_key(id)
		if slot != null:
			leader.equip_item(slot, item)
		elif not PartyManager.inventory.add(item):
			push_warning("StartingParty: no room in the bag for %s" % id)


## The .tres basenames in dir, sorted. An exported build lists them as
## .tres.remap, so that suffix is stripped too.
static func _resource_ids(dir: String) -> Array[String]:
	var ids: Array[String] = []
	for file in DirAccess.get_files_at(dir):
		file = file.trim_suffix(".remap")
		if file.ends_with(".tres"):
			ids.append(file.get_basename())
	ids.sort()
	return ids
