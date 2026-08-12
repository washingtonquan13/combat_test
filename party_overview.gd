extends Control
## The party's "character sheet" — stats, equipment, and (for now) the
## other tabs the old GURPS-project version stubbed out and never wired
## up either. Opens showing whichever unit is currently active
## (PlayerInteractionState.get_active_unit() — same resolution every
## other player-facing system already uses), toggled by the
## open_party_overview action (C).
##
## No in-panel character switcher — EquipSlot's equipped_item is scene-
## local state with nowhere on Unit to persist to between characters
## (Unit doesn't track equipment at all yet), and solving that properly
## belongs with the stash/loot-transfer pass, not bolted on here as a
## half-measure. Close and reopen on a different unit instead.
##
## Combat design goals (see memory: combat_design_goals): only
## ST/DX/IQ/HT/Will/Per, HP/FP, DR, and Move are shown. Dodge/Parry/
## Block/SM/Basic Lift/Speed existed in the old GURPS-project version
## and are deliberately NOT here — this project's combat stays fast and
## low-roll, not a full active-defense layer.
##
## Alignment shows "—" — nothing on Unit tracks accumulated alignment
## yet (DialogueChoice.alignment_name is a per-choice tag, logged, never
## summed anywhere). The row stays so the layout doesn't need to change
## the moment that tracking exists; it just has nothing real to show yet.

## No separate "inventory" tab/key anymore — the inventory grid lives as
## a third column inside the character panel itself now (see
## InventoryColumn), always visible alongside stats and equipment rather
## than something you tab away to. "Character" is the one real,
## permanently-shown view; Spellbook/Journal/Encyclopedia/Map still share
## one placeholder panel, same as before.
@onready var _tab_buttons: Dictionary = {
	"character": $TopBar/TabCharacter,
	"spellbook": $TopBar/TabSpellbook,
	"journal": $TopBar/TabJournal,
	"encyclopedia": $TopBar/TabEncyclopedia,
	"map": $TopBar/TabMap,
}
@onready var _panels: Dictionary = {
	"character": $ContentArea/CharacterPanel,
	"spellbook": $ContentArea/PlaceholderPanel,
	"journal": $ContentArea/PlaceholderPanel,
	"encyclopedia": $ContentArea/PlaceholderPanel,
	"map": $ContentArea/PlaceholderPanel,
}

@onready var _name_label: Label = $ContentArea/CharacterPanel/StatsColumn/ScrollContainer/VBoxContainer/NameLabel
@onready var _alignment_label: Label = $ContentArea/CharacterPanel/StatsColumn/ScrollContainer/VBoxContainer/AlignmentLabel
@onready var _hp_value: Label = $ContentArea/CharacterPanel/StatsColumn/ScrollContainer/VBoxContainer/HPHeader/HPValue
@onready var _hp_fill: ColorRect = $ContentArea/CharacterPanel/StatsColumn/ScrollContainer/VBoxContainer/HPBar/Fill
@onready var _fp_value: Label = $ContentArea/CharacterPanel/StatsColumn/ScrollContainer/VBoxContainer/FPHeader/FPValue
@onready var _fp_fill: ColorRect = $ContentArea/CharacterPanel/StatsColumn/ScrollContainer/VBoxContainer/FPBar/Fill
@onready var _st_value: Label = $ContentArea/CharacterPanel/StatsColumn/ScrollContainer/VBoxContainer/AttributeGrid/STValue
@onready var _dx_value: Label = $ContentArea/CharacterPanel/StatsColumn/ScrollContainer/VBoxContainer/AttributeGrid/DXValue
@onready var _iq_value: Label = $ContentArea/CharacterPanel/StatsColumn/ScrollContainer/VBoxContainer/AttributeGrid/IQValue
@onready var _ht_value: Label = $ContentArea/CharacterPanel/StatsColumn/ScrollContainer/VBoxContainer/AttributeGrid/HTValue
@onready var _will_value: Label = $ContentArea/CharacterPanel/StatsColumn/ScrollContainer/VBoxContainer/AttributeGrid/WillValue
@onready var _per_value: Label = $ContentArea/CharacterPanel/StatsColumn/ScrollContainer/VBoxContainer/AttributeGrid/PerValue
@onready var _dr_value: Label = $ContentArea/CharacterPanel/StatsColumn/ScrollContainer/VBoxContainer/DRRow/Value
@onready var _move_value: Label = $ContentArea/CharacterPanel/StatsColumn/ScrollContainer/VBoxContainer/MoveRow/Value
@onready var _thrust_value: Label = $ContentArea/CharacterPanel/StatsColumn/ScrollContainer/VBoxContainer/ThrustRow/Value
@onready var _swing_value: Label = $ContentArea/CharacterPanel/StatsColumn/ScrollContainer/VBoxContainer/SwingRow/Value
@onready var _portrait: TextureRect = $ContentArea/CharacterPanel/EquipmentColumn/VBoxContainer/Portrait

@onready var _sort_button: Button = $ContentArea/CharacterPanel/InventoryColumn/VBoxContainer/SortButton
@onready var _inventory: Inventory = $ContentArea/CharacterPanel/InventoryColumn/VBoxContainer/Inventory

var _unit: Unit = null


func _ready() -> void:
	visible = false

	for tab_name in _tab_buttons:
		_tab_buttons[tab_name].pressed.connect(_show_tab.bind(tab_name))
	$TopBar/CloseButton.pressed.connect(func(): visible = false)
	_sort_button.pressed.connect(_inventory.sort_items)

	_show_tab("character")


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
	_refresh_character_panel()
	visible = true
	_show_tab("character")


func _show_tab(tab_name: String) -> void:
	for panel in _panels.values():
		panel.visible = false
	_panels[tab_name].visible = true

	for key in _tab_buttons:
		_tab_buttons[key].disabled = (key == tab_name)


func _refresh_character_panel() -> void:
	_name_label.text = _unit.name
	_alignment_label.text = "—"

	_hp_value.text = "%d / %d" % [_unit.current_hp, _unit.maximum_hp]
	_hp_fill.anchor_right = _fraction(_unit.current_hp, _unit.maximum_hp)
	_fp_value.text = "%d / %d" % [_unit.current_fp, _unit.maximum_fp]
	_fp_fill.anchor_right = _fraction(_unit.current_fp, _unit.maximum_fp)

	_st_value.text = str(_unit.strength)
	_dx_value.text = str(_unit.dexterity)
	_iq_value.text = str(_unit.intelligence)
	_ht_value.text = str(_unit.health)
	_will_value.text = str(_unit.will)
	_per_value.text = str(_unit.perception)

	_dr_value.text = str(_unit.damage_reduction)
	_move_value.text = str(_unit.move)

	_thrust_value.text = _describe_die(_unit.thrust)
	_swing_value.text = _describe_die(_unit.swing)

	_portrait.texture = _unit.portrait_texture


func _fraction(current: int, maximum: int) -> float:
	if maximum <= 0:
		return 0.0
	return clampf(float(current) / float(maximum), 0.0, 1.0)


func _describe_die(die: Die) -> String:
	var text: String = "%dd%d" % [die.count, die.sides]
	if die.bonus > 0:
		text += "+%d" % die.bonus
	elif die.bonus < 0:
		text += str(die.bonus)
	return text
