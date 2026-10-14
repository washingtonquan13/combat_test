extends AiTestCase
## The overworld names where you are, the SMT way: the district's name in
## the corner from the moment you arrive, and a banner only when you walk
## into a different one, after a moment's settling so a border does not
## flicker.
##
## Run through the real path (a synthetic world host, the arena, then the
## door out to the overworld) and asserted on what is RENDERED: the label
## is visible in the tree and says the name, not merely that the overworld
## picked a district. The label lives in MainRoot, which tests do not
## load, so the same nodes are built here with its script.
##
## The districts are world/city_overworld.tscn's Districts node, written
## by tools/blockout/districts.py and edited by hand from there.

const HOME := &"test_arena"
const OVERWORLD := &"overworld"
## Arriving through the overworld's door back to the arena, Congo Square,
## which the generator gave to the French Quarter.
const ARRIVAL_NAME := "French Quarter"
## Inside the CBD, well away from its borders.
const ELSEWHERE := Vector3(-4238.1, 0.5, 3390.3)
const ELSEWHERE_NAME := "CBD"

## A point well inside each district on the live map, from the
## generator's own districts.json. If the borders are moved by hand,
## these may need moving with them.
const INTERIOR := {
	"French Quarter": Vector3(-3174.8, 0.5, 2131.4),
	"CBD": Vector3(-4238.1, 0.5, 3390.3),
	"Marigny and Bywater": Vector3(-1857.2, 0.5, 1339.2),
	"Garden District": Vector3(-4249.5, 0.5, 5494.2),
	"Uptown and Audubon": Vector3(-7128.8, 0.5, 4988.1),
	"Carrollton and Riverbend": Vector3(-7454.1, 0.5, 2401.6),
	"Mid-City": Vector3(-6123.7, 0.5, 1246.8),
	"Bayou St. John": Vector3(-4070.2, 0.5, 315.8),
	"Lakeview": Vector3(-6318.5, 0.5, -3553.3),
	"Algiers Point": Vector3(-1651.3, 0.5, 4046.3),
	"Holy Cross": Vector3(59.0, 0.5, 2606.5),
	"Gentilly": Vector3(-2321.6, 0.5, -3382.4),
	"Lower Ninth Ward": Vector3(2646.4, 0.5, 861.4),
	"Lake Forest": Vector3(1836.2, 0.5, -4007.1),
	"Village de l'Est": Vector3(6445.3, 0.5, -2412.1),
	"Lower Algiers": Vector3(3617.6, 0.5, 5235.9),
}

var _host: Control
var _label: Control
var _saved_host: Control = null
var _saved_attention: Array[Node] = []
var _snapshot: Dictionary = {}


func run() -> void:
	if not _install_synthetic_host():
		check("SETUP: synthetic world host installed", false)
		_restore()
		return
	_snapshot_globals()
	_install_label()

	PartyManager.clear_members()
	PartyManager.load_state({})
	WorldManager.load_area(HOME)
	await get_tree().process_frame
	check("in the arena the label shows nothing", not _label.is_visible_in_tree(),
		"showing '%s'" % _corner().text)

	WorldManager.load_area(OVERWORLD)
	await _wait(0.5)
	var world: Node = WorldManager.current_world()
	var districts: Node = world.get_node_or_null(^"Districts") if world else null
	var count := districts.get_child_count() if districts else 0
	check("the overworld has its districts", count > 0, "%d district node(s)" % count)
	if count == 0:
		_restore()
		return
	for district_name in INTERIOR:
		var here: OverworldDistrict = world._district_at(INTERIOR[district_name])
		check("a point inside %s is in %s" % [district_name, district_name],
			here != null and here.display_name == district_name,
			"found %s" % (here.display_name if here else "nothing"))

	check("arriving names the district at once", _label.is_visible_in_tree() and _corner().text == ARRIVAL_NAME,
		"visible %s, showing '%s'" % [_label.is_visible_in_tree(), _corner().text])
	check("but without a banner: arriving is not crossing a border", not _banner().visible)

	var avatar: Node3D = world._active_avatar()
	if avatar == null:
		check("SETUP: an avatar to walk", false)
		_restore()
		return
	avatar.global_position = ELSEWHERE
	await _wait(world.district_settle_time * 0.5)
	check("a new district waits before it is named", _corner().text == ARRIVAL_NAME,
		"showing '%s' after %.1f s" % [_corner().text, world.district_settle_time * 0.5])
	await _wait(world.district_settle_time + 0.5)
	check("then the corner says where you are now", _corner().text == ELSEWHERE_NAME,
		"showing '%s'" % _corner().text)
	check("and the banner announces it", _banner().is_visible_in_tree() and _banner_text() == ELSEWHERE_NAME,
		"banner visible %s, '%s'" % [_banner().is_visible_in_tree(), _banner_text()])

	WorldManager.load_area(HOME)
	await get_tree().process_frame
	check("leaving the overworld takes the name away", not _label.is_visible_in_tree(),
		"showing '%s'" % _corner().text)
	_restore()


func _wait(seconds: float) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame


func _corner() -> Label:
	return _label.get_node(^"Corner")


func _banner() -> Control:
	return _label.get_node(^"Banner")


func _banner_text() -> String:
	return (_label.get_node(^"Banner/Label") as Label).text


func _install_label() -> void:
	_label = Control.new()
	_label.name = "AreaLabel"
	var corner := Label.new()
	corner.name = "Corner"
	_label.add_child(corner)
	var banner := PanelContainer.new()
	banner.name = "Banner"
	banner.add_child(Label.new())
	banner.get_child(0).name = "Label"
	_label.add_child(banner)
	_label.set_script(load("res://ui/area_label.gd"))
	_root.add_child(_label)


func _install_synthetic_host() -> bool:
	_saved_host = WorldManager._world_host
	_saved_attention = WorldManager._attention_nodes.duplicate()
	_host = Control.new()
	_root.add_child(_host)
	WorldManager.register_world_host(_host)
	var none: Array[Node] = []
	WorldManager.register_attention_nodes(none)
	return WorldManager.can_travel()


func _snapshot_globals() -> void:
	_snapshot = {
		"flags": FlagManager.save_state(),
		"party": PartyManager.save_state(),
		"demons": DemonRoster.save_state(),
		"currency": CurrencyManager.save_state(),
	}


func _restore() -> void:
	WorldManager.discard_worlds()
	if not _snapshot.is_empty():
		FlagManager.load_state(_snapshot["flags"])
		PartyManager.load_state(_snapshot["party"])
		DemonRoster.load_state(_snapshot["demons"])
		CurrencyManager.load_state(_snapshot["currency"])
	while PartyManager.groups.size() > 1:
		PartyManager.groups[0].absorb(PartyManager.groups[1])
		PartyManager.groups.remove_at(1)
	if not PartyManager.groups.is_empty():
		PartyManager.active_group = PartyManager.groups[0]
	WorldManager._world_host = _saved_host
	WorldManager._attention_nodes = _saved_attention
	if is_instance_valid(_host):
		_host.queue_free()
	if is_instance_valid(_label):
		_label.queue_free()
