extends Control
## The party's "character sheet." Two real sections, both anchored
## 3-column layouts sharing the SAME StatsColumn component (see
## stats_column.gd) on the left, so a unit's stats read identically in
## both places instead of two hand-authored copies drifting apart:
##   Inventory (first tab, default) — Stats | Equipment paperdoll | Items
##   Character (second tab)         — Stats | Alignment grid | Skills
## Spellbook/Journal/Encyclopedia/Map are the old GURPS-project version's
## remaining tabs, still stubbed, sharing one placeholder.
##
## Opens showing whichever unit is currently active
## (PlayerInteractionState.get_active_unit()), toggled by the
## open_party_overview action (C).
##
## No in-panel character switcher — EquipSlot's equipped_item is scene-
## local state with nowhere on Unit to persist to between characters
## (Unit doesn't track equipment at all yet), and solving that properly
## belongs with the stash/loot-transfer pass, not bolted on here as a
## half-measure. Close and reopen on a different unit instead.
##
## Alignment grid: 9 cells, Chaos/Neutral/Law x Dark/Neutral/Light,
## columns matching Unit.alignment_category() and rows matching
## Unit.tendency_category() — the SAME category logic Unit itself owns,
## not re-derived here. Exactly one cell gets _alignment_highlight_style;
## the rest are reset to no override every refresh, so there's never a
## stale highlight left on the wrong cell.
##
## Skills are real — one row per Unit.get_skills() entry, level computed
## through SkillCalculator (the exact same resolution a dialogue skill
## check would use, so this can never disagree with what a real check
## rolls against). Built dynamically each refresh, same "rebuild rather
## than diff" approach party_panel.gd/ability_hotbar.gd already use for
## their own variable-length per-unit lists.

@onready var _tab_buttons: Dictionary = {
	"inventory": $TopBar/TabInventory,
	"character": $TopBar/TabCharacter,
	"spellbook": $TopBar/TabSpellbook,
	"journal": $TopBar/TabJournal,
	"encyclopedia": $TopBar/TabEncyclopedia,
	"map": $TopBar/TabMap,
}
@onready var _panels: Dictionary = {
	"inventory": $ContentArea/InventoryPanel,
	"character": $ContentArea/CharacterPanel,
	"spellbook": $ContentArea/PlaceholderPanel,
	"journal": $ContentArea/PlaceholderPanel,
	"encyclopedia": $ContentArea/PlaceholderPanel,
	"map": $ContentArea/PlaceholderPanel,
}

@onready var _inventory_stats: StatsColumn = $ContentArea/InventoryPanel/StatsColumn
@onready var _character_stats: StatsColumn = $ContentArea/CharacterPanel/StatsColumn

@onready var _portrait: TextureRect = $ContentArea/InventoryPanel/EquipmentColumn/VBoxContainer/Portrait
@onready var _sort_button: Button = $ContentArea/InventoryPanel/InventoryColumn/VBoxContainer/SortButton
@onready var _inventory: Inventory = $ContentArea/InventoryPanel/InventoryColumn/VBoxContainer/Inventory

## (alignment_category, tendency_category) -> the PanelContainer cell —
## built once in _ready() from the 9 hand-authored grid cells, so
## _refresh_alignment_grid() never needs a match/if chain to find the
## right one.
var _alignment_cells: Dictionary = {}
var _alignment_highlight_style: StyleBoxFlat

@onready var _skill_list: VBoxContainer = $ContentArea/CharacterPanel/SkillColumn/VBoxContainer/ScrollContainer/SkillList

var _unit: Unit = null


func _ready() -> void:
	visible = false

	var grid: GridContainer = $ContentArea/CharacterPanel/AlignmentColumn/VBoxContainer/AlignmentGrid
	_alignment_cells = {
		Vector2i(-1, 1): grid.get_node("ChaosLight"), Vector2i(0, 1): grid.get_node("NeutralLight"), Vector2i(1, 1): grid.get_node("LawLight"),
		Vector2i(-1, 0): grid.get_node("ChaosNeutral"), Vector2i(0, 0): grid.get_node("TrueNeutral"), Vector2i(1, 0): grid.get_node("LawNeutral"),
		Vector2i(-1, -1): grid.get_node("ChaosDark"), Vector2i(0, -1): grid.get_node("NeutralDark"), Vector2i(1, -1): grid.get_node("LawDark"),
	}
	_alignment_highlight_style = StyleBoxFlat.new()
	_alignment_highlight_style.bg_color = Color(1, 1, 1, 0.18)

	for tab_name in _tab_buttons:
		_tab_buttons[tab_name].pressed.connect(_show_tab.bind(tab_name))
	$TopBar/CloseButton.pressed.connect(func(): visible = false)
	_sort_button.pressed.connect(_inventory.sort_items)

	_show_tab("inventory")


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("open_party_overview") or DialogueManager.is_active():
		return

	if visible:
		visible = false
		return

	var unit: Unit = PlayerInteractionState.get_active_unit()
	if unit:
		open_for(unit)


func open_for(unit: Unit) -> void:
	_unit = unit
	_inventory_stats.refresh(unit)
	_character_stats.refresh(unit)
	_portrait.texture = unit.portrait_texture
	_refresh_alignment_grid(unit)
	_refresh_skill_list(unit)
	visible = true
	_show_tab("inventory")


func _show_tab(tab_name: String) -> void:
	for panel in _panels.values():
		panel.visible = false
	_panels[tab_name].visible = true

	for key in _tab_buttons:
		_tab_buttons[key].disabled = (key == tab_name)


func _refresh_alignment_grid(unit: Unit) -> void:
	var current: Vector2i = Vector2i(unit.alignment_category(), unit.tendency_category())
	for key in _alignment_cells:
		var cell: PanelContainer = _alignment_cells[key]
		if key == current:
			cell.add_theme_stylebox_override("panel", _alignment_highlight_style)
		else:
			cell.remove_theme_stylebox_override("panel")


func _refresh_skill_list(unit: Unit) -> void:
	for child in _skill_list.get_children():
		child.queue_free()

	var skills: Array[SkillInstance] = unit.get_skills()
	if skills.is_empty():
		var empty_label := Label.new()
		empty_label.modulate = Color(1, 1, 1, 0.5)
		empty_label.text = "No skills trained yet."
		_skill_list.add_child(empty_label)
		return

	for skill in skills:
		var result: SkillCheckResult = SkillCalculator.get_skill_level(unit, skill.skill_data.skill_name)

		var row := HBoxContainer.new()
		var name_label := Label.new()
		name_label.text = skill.skill_data.skill_name
		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var level_label := Label.new()
		level_label.text = str(result.skill_level)

		row.add_child(name_label)
		row.add_child(spacer)
		row.add_child(level_label)
		_skill_list.add_child(row)
