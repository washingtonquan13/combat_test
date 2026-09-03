class_name DebugSpawnPanel
extends Control
## The Spawn tab's content — debug-only "place a test unit in the 3D
## world" tool. Root-level like DemonCompendiumPanel, referenced via
## @onready from party_overview.gd the same way.
##
## Unlike DemonCompendiumPanel (only one row debug-gated), the WHOLE tab
## is debug-only: party_overview.gd hides %TabSpawn itself, and this
## script's own _ready()/refresh() additionally no-op outside a debug
## build as defense in depth — same belt-and-suspenders reasoning
## DemonCompendiumPanel's own debug grant row already uses.
##
## Picking a unit + a faction + Arm Spawn hands both to
## DebugSpawner.arm(); actual placement happens on the next world click
## (see debug_spawner.gd's own spawn_at and SpawningIntent, which — same as
## Add to Party below — also calls PartyManager.add_member() for a
## friendly placement, so both spawn paths keep the roster in sync
## instead of one silently drifting from what party_panel shows).
##
## Party add/remove lives in this same tab rather than a new one —
## reuses the exact unit picker above (Add to Party just skips arming/
## the ground click and places immediately), and this was already the
## established "the whole tab is debug tools" home before this was added.

@onready var _unit_list: ItemList = %SpawnUnitList
@onready var _friendly_button: Button = %FriendlyButton
@onready var _hostile_button: Button = %HostileButton
@onready var _status_label: Label = %SpawnStatusLabel
@onready var _arm_button: Button = %ArmSpawnButton
@onready var _add_to_party_button: Button = %AddToPartyButton
@onready var _party_list: ItemList = %PartyMembersList
@onready var _remove_from_party_button: Button = %RemoveFromPartyButton
@onready var _restore_button: Button = %RestoreHpFpButton

var _definitions: Array[UnitDefinition] = []
var _selected_faction: StringName = &"enemy"
## Index-for-index with _party_list's rows — same "the list item is just
## text, this array is the real reference" convention
## DemonCompendiumPanel's own _roster_entries already uses.
var _party_entries: Array[Unit] = []


func _ready() -> void:
	if not OS.is_debug_build():
		return
	_friendly_button.pressed.connect(_on_faction_pressed.bind(&"player"))
	_hostile_button.pressed.connect(_on_faction_pressed.bind(&"enemy"))
	_arm_button.pressed.connect(_on_arm_pressed)
	_add_to_party_button.pressed.connect(_on_add_to_party_pressed)
	_party_list.item_selected.connect(func(_i): _update_remove_button())
	_remove_from_party_button.pressed.connect(_on_remove_from_party_pressed)
	_restore_button.pressed.connect(_on_restore_pressed)
	DebugSpawner.armed_changed.connect(func(_d, _f): _update_status())
	PartyManager.member_added.connect(func(_u): _refresh_party_list())
	PartyManager.member_removed.connect(func(_u): _refresh_party_list())
	_populate_list()
	_update_status()
	_refresh_party_list()


func refresh() -> void:
	if not OS.is_debug_build():
		return
	_populate_list()
	_update_status()
	_refresh_party_list()


func _populate_list() -> void:
	_definitions = SpawnableUnitDatabase.get_all()
	_unit_list.clear()
	for definition in _definitions:
		_unit_list.add_item(definition.display_name)


func _on_faction_pressed(faction: StringName) -> void:
	_selected_faction = faction


func _on_arm_pressed() -> void:
	var selected: PackedInt32Array = _unit_list.get_selected_items()
	if selected.is_empty():
		return
	DebugSpawner.arm(_definitions[selected[0]], _selected_faction)


func _update_status() -> void:
	if DebugSpawner.armed_definition:
		_status_label.text = "Armed: %s (%s) — click the world to place." % [DebugSpawner.armed_definition.display_name, DebugSpawner.armed_faction]
	else:
		_status_label.text = "Not armed."


## Places the selected unit immediately (no ground click, no arming) and
## adds it straight to PartyManager — this is the actual proof, alongside
## character creation, that party membership never needed hand-placed
## scene content. Always player-side regardless of the Friendly/Hostile
## toggle above (a "hostile party member" isn't a real concept), and
## deliberately does NOT go through .definition's faction cascade for
## that reason — same override-after-cascade ordering
## debug_spawner.gd's own spawn_at already uses.
func _on_add_to_party_pressed() -> void:
	var selected: PackedInt32Array = _unit_list.get_selected_items()
	if selected.is_empty():
		return

	var definition: UnitDefinition = _definitions[selected[0]]
	var spawned: Unit = definition.unit_scene.instantiate()
	spawned.definition = definition
	spawned.faction = Unit.PLAYER_FACTION

	var anchor: Unit = PartyManager.leader
	var spawn_point: Vector3 = anchor.global_position + Vector3(randf_range(-2.0, 2.0), 0.0, randf_range(-2.0, 2.0)) if anchor else Vector3.ZERO

	WorldManager.spawn_parent().add_child(spawned)
	spawned.global_position = spawn_point

	PartyManager.add_member(spawned)


func _refresh_party_list() -> void:
	_party_entries = PartyManager.members
	_party_list.clear()
	for unit in _party_entries:
		var suffix: String = "  (leader)" if PartyManager.is_leader(unit) else ""
		_party_list.add_item(unit.get_display_name() + suffix)
	_update_remove_button()


func _update_remove_button() -> void:
	_remove_from_party_button.disabled = _selected_party_entry() == null


func _selected_party_entry() -> Unit:
	var selected: PackedInt32Array = _party_list.get_selected_items()
	if selected.is_empty():
		return null
	return _party_entries[selected[0]]


## Removes the roster entry AND despawns the unit — a debug "remove from
## party" that leaves the unit standing around, no longer tracked but
## still physically present, would just be confusing. (PartyManager
## itself deliberately doesn't decide this — see its own remove_member()
## doc comment — this is that decision, made here.)
func _on_remove_from_party_pressed() -> void:
	var target: Unit = _selected_party_entry()
	if not target:
		return
	PartyManager.remove_member(target)
	target.queue_free()


## Stands in for the recovery model this project doesn't have yet (see
## FlightRules/FpDrainBehavior's own headers — FP is spent, nothing
## restores it). Covers BOTH halves of where FP/HP can currently live:
## PartyManager.members (live Units, present or not depending on
## spawns_party() — see WorldManager) AND DemonRoster's own OwnedDemon
## entries, whose current_hp/current_fp persist independently of any
## live Unit (a dismissed demon isn't in members at all — see
## OwnedDemon's own header). Restoring only one half would silently miss
## the other.
func _on_restore_pressed() -> void:
	for unit in PartyManager.members:
		unit.current_hp = unit.maximum_hp
		unit.current_fp = unit.maximum_fp

	for owned in DemonRoster.all_owned():
		owned.current_hp = owned.species.max_hp
		owned.current_fp = owned.species.max_fp
