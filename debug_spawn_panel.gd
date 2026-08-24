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
## (see ground_click_target.gd's debug-spawn branch).

@onready var _unit_list: ItemList = %SpawnUnitList
@onready var _friendly_button: Button = %FriendlyButton
@onready var _hostile_button: Button = %HostileButton
@onready var _status_label: Label = %SpawnStatusLabel
@onready var _arm_button: Button = %ArmSpawnButton

var _definitions: Array[UnitDefinition] = []
var _selected_faction: StringName = &"enemy"


func _ready() -> void:
	if not OS.is_debug_build():
		return
	_friendly_button.pressed.connect(_on_faction_pressed.bind(&"player"))
	_hostile_button.pressed.connect(_on_faction_pressed.bind(&"enemy"))
	_arm_button.pressed.connect(_on_arm_pressed)
	DebugSpawner.armed_changed.connect(func(_d, _f): _update_status())
	_populate_list()
	_update_status()


func refresh() -> void:
	if not OS.is_debug_build():
		return
	_populate_list()
	_update_status()


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
