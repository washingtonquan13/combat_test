extends AiTestCase
## The party panel, rendered — is a record row dimmed or not.
##
## The rest of this suite exercises managers. Nothing anywhere in it loads
## party_panel.gd, which is how `group.area_id` survived the rename that
## removed that property: 346 green checks, and the first attempt to travel
## with a split party threw "Invalid access to property or key 'area_id'"
## in the real game.
##
## GDScript does not catch that read when the script is parsed — verified
## by reintroducing it, which still loads clean — so the only thing that
## catches it is running the code and asserting what it DREW. A runtime
## error of that kind does not throw: it prints, abandons the call whose
## argument it was evaluating, and leaves the portrait at its default
## colour. Reading the colour back is what gives this teeth.
##
## Asserted against "not the default" rather than the exact dimmed value,
## so restyling the panel does not fail a test about locations.

const HOME := &"test_arena"
const AWAY := &"test_area_2"
const UNTOUCHED := Color(1, 1, 1, 1)

var _panel: PartyPanel
var _host: Control
var _record: PartyMemberData
var _away: PartyGroup
var _saved_host: Control = null
var _saved_attention: Array[Node] = []


func run() -> void:
	_saved_host = WorldManager._world_host
	_saved_attention = WorldManager._attention_nodes.duplicate()
	_host = Control.new()
	_root.add_child(_host)
	WorldManager.register_world_host(_host)
	var none: Array[Node] = []
	WorldManager.register_attention_nodes(none)

	if not WorldManager.load_area(HOME):
		check("SETUP: an area to be looking at", false)
		_restore()
		return
	await get_tree().process_frame

	_panel = PartyPanel.new()
	_panel.slot_scene = load("res://unit_portrait.tscn")
	# _core_container is @onready on $CoreContainer, so the child has to
	# exist before the panel enters the tree.
	var core := VBoxContainer.new()
	core.name = "CoreContainer"
	_panel.add_child(core)
	_root.add_child(_panel)
	await get_tree().process_frame

	# A member with no Unit anywhere — the only kind of row that reaches
	# _mark_record_row, and the reason this path is never hit by a party
	# that has stayed together.
	_record = PartyMemberData.new()
	_record.id = &"panel_row_record"
	_record.display_name = "Someone Far Away"
	_away = PartyGroup.new()
	_away.abstract_area_id = AWAY
	_away.records.append(_record)
	PartyManager.groups.append(_away)

	_panel._add_data_slot(_record)
	var row: Node = _panel._core_rows.get(_record)
	if not is_instance_valid(row) or row.get_child_count() == 0:
		check("SETUP: the record got a row", false)
		_restore()
		return
	var portrait: Control = row.get_child(0)

	_panel._mark_absent_members()
	check("a member standing in another area is dimmed",
		portrait.modulate != UNTOUCHED,
		"left untouched — set_elsewhere was never reached")

	# And not simply always dimmed: bring them to the area on screen.
	_away.abstract_area_id = HOME
	_panel._mark_absent_members()
	check("and one in the area on screen is not",
		portrait.modulate == UNTOUCHED,
		"dimmed a member who is standing right here")

	_restore()


func _restore() -> void:
	if is_instance_valid(_away):
		PartyManager.groups.erase(_away)
	if is_instance_valid(_panel):
		_panel.queue_free()
	WorldManager.unload(true)
	WorldManager._world_host = _saved_host
	WorldManager._attention_nodes = _saved_attention
	if is_instance_valid(_host):
		_host.queue_free()
