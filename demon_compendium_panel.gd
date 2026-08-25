class_name DemonCompendiumPanel
extends Control
## The Demons tab's content — roster browsing plus fusion, both reading
## and writing DemonRoster directly. Root-level like party_panel.gd/
## stash_panel.gd, referenced via @onready from party_overview.gd the
## same way AlignmentGrid/StatsColumn are — this script owns everything
## under its own DemonPanel node, party_overview.gd just calls refresh().
##
## Lists individual OwnedDemon instances everywhere, never grouped by
## species — two same-species demons can be in different HP/FP states,
## which is exactly the information a species-grouped view would hide.
## Fusion needs two SEPARATE pickers (not one list with a two-item
## selection) so choosing the same physical row twice isn't possible by
## construction, rather than needing an extra "can't fuse a demon with
## itself" check layered on top.

@onready var _roster_list: ItemList = %RosterList
@onready var _slot_a_list: ItemList = %SlotAList
@onready var _slot_b_list: ItemList = %SlotBList
@onready var _fuse_button: Button = %FuseButton
@onready var _fusion_result_label: Label = %FusionResultLabel
@onready var _debug_grant_row: HBoxContainer = %DebugGrantRow
@onready var _grant_species_list: OptionButton = %GrantSpeciesList
@onready var _grant_button: Button = %GrantButton

## data/fusion_charts/fusion_chart.tres — the one authored chart, loaded
## once. Lives in its own folder, not data/demons/, because it isn't a
## demon — it's a cross-cutting rules table that happens to reference
## demon orders, same reasoning a future "fusion accident" or "fusion
## while cursed" chart would want its own file in the same folder
## rather than getting mixed in with the demons themselves.
const FUSION_CHART_PATH: String = "res://data/fusion_charts/fusion_chart.tres"

var _fusion_chart: FusionChart
## ItemList items are just text/index — these are the actual OwnedDemon
## each row refers to, index-for-index, same pattern party_overview.gd
## already uses for its Journal's quest list.
var _roster_entries: Array[OwnedDemon] = []
var _slot_a_entries: Array[OwnedDemon] = []
var _slot_b_entries: Array[OwnedDemon] = []
var _grant_species: Array[UnitDefinition] = []


func _ready() -> void:
	_fusion_chart = load(FUSION_CHART_PATH) as FusionChart
	_debug_grant_row.visible = OS.is_debug_build()

	_slot_a_list.item_selected.connect(func(_i): _update_fusion_preview())
	_slot_b_list.item_selected.connect(func(_i): _update_fusion_preview())
	_fuse_button.pressed.connect(_on_fuse_pressed)
	if OS.is_debug_build():
		_grant_button.pressed.connect(_on_grant_pressed)


func refresh() -> void:
	_roster_entries = DemonRoster.all_owned()
	_populate_demon_list(_roster_list, _roster_entries)

	_slot_a_entries = DemonRoster.all_owned()
	_populate_demon_list(_slot_a_list, _slot_a_entries)
	_slot_b_entries = DemonRoster.all_owned()
	_populate_demon_list(_slot_b_list, _slot_b_entries)

	_update_fusion_preview()

	if OS.is_debug_build():
		_refresh_grant_list()


func _populate_demon_list(list: ItemList, entries: Array[OwnedDemon]) -> void:
	list.clear()
	for owned in entries:
		list.add_item("%s (HP %d/%d)" % [owned.species.display_name, owned.current_hp, owned.species.max_hp])


func _update_fusion_preview() -> void:
	var a: OwnedDemon = _selected_entry(_slot_a_list, _slot_a_entries)
	var b: OwnedDemon = _selected_entry(_slot_b_list, _slot_b_entries)

	if not a or not b:
		_fusion_result_label.text = "Select two demons to fuse."
		_fuse_button.disabled = true
		return

	if a == b:
		_fusion_result_label.text = "Pick two different demons."
		_fuse_button.disabled = true
		return

	var result: UnitDefinition = FusionCalculator.compute_fusion(_fusion_chart, a.species, b.species)
	if not result:
		_fusion_result_label.text = "These two don't fuse into anything."
		_fuse_button.disabled = true
		return

	_fusion_result_label.text = "Result: %s" % result.display_name
	_fuse_button.disabled = false


func _on_fuse_pressed() -> void:
	var a: OwnedDemon = _selected_entry(_slot_a_list, _slot_a_entries)
	var b: OwnedDemon = _selected_entry(_slot_b_list, _slot_b_entries)
	if not a or not b or a == b:
		return

	var result: UnitDefinition = FusionCalculator.compute_fusion(_fusion_chart, a.species, b.species)
	if not result:
		return

	DemonRoster.release(a)
	DemonRoster.release(b)
	DemonRoster.recruit(result)
	refresh()


func _selected_entry(list: ItemList, entries: Array[OwnedDemon]) -> OwnedDemon:
	var selected: PackedInt32Array = list.get_selected_items()
	if selected.is_empty():
		return null
	return entries[selected[0]]


func _refresh_grant_list() -> void:
	_grant_species = DemonDatabase.get_all()
	_grant_species_list.clear()
	for species in _grant_species:
		_grant_species_list.add_item(species.display_name)


func _on_grant_pressed() -> void:
	if _grant_species.is_empty():
		return
	var index: int = _grant_species_list.selected
	if index < 0:
		return
	DemonRoster.recruit(_grant_species[index])
	refresh()
