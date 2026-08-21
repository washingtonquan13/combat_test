class_name PartyOverview
extends Control
## The party's "character sheet." Two real sections, both anchored
## 3-column layouts sharing the SAME StatsColumn component (see
## stats_column.gd) on the left, so a unit's stats read identically in
## both places instead of two hand-authored copies drifting apart:
##   Inventory (first tab, default) — Stats | Equipment paperdoll | Items
##   Character (second tab)         — Stats | Alignment grid | Skills
## Spellbook/Encyclopedia/Map are the old GURPS-project version's
## remaining tabs, still stubbed, sharing one placeholder. Journal is
## real — a master-detail split (see _refresh_journal_list()): every
## started QuestDatabase.get_all() entry gets a row in the left
## ItemList, and _show_quest_detail() renders the SELECTED one's full
## reached_stages() log on the right, most recent at full brightness,
## earlier ones dimmed. A quest's progress is never stored here or
## anywhere quest-specific — Quest.current_stage()/reached_stages()
## derive it by reading FlagManager directly, the same world state
## dialogue already writes to via DialogueChoice.sets_flag/DialogueEffect.
##
## Opens showing whichever unit is currently active
## (PlayerInteractionState.get_active_unit()), toggled by the
## open_party_overview action (C).
##
## Still no in-panel character switcher, but the underlying gap that
## used to justify deferring one is fixed: equipment now persists per-
## unit (see UnitEquipment), and _swap_equipment() below reparents the
## 16 shared EquipSlots' items out to the outgoing unit's storage and in
## from the incoming unit's, the same pattern StashPanel already uses
## for a chest's single Inventory, just looped over 16 slots. Close and
## reopen on a different unit still — nothing calls this mid-session yet.
##
## Alignment display: AlignmentTitle shows the category label (the same
## Chaos/Neutral/Law x Dark/Neutral/Light categories Unit itself owns,
## via alignment_category()/tendency_category()) and AlignmentGrid (see
## alignment_grid.gd) plots a dot at the unit's exact raw alignment/
## tendency position underneath it — continuous position, discrete title.
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
	"demons": $TopBar/TabDemons,
	"spellbook": $TopBar/TabSpellbook,
	"journal": $TopBar/TabJournal,
	"encyclopedia": $TopBar/TabEncyclopedia,
	"map": $TopBar/TabMap,
}
@onready var _panels: Dictionary = {
	"inventory": $ContentArea/InventoryPanel,
	"character": $ContentArea/CharacterPanel,
	"demons": $ContentArea/DemonPanel,
	"spellbook": $ContentArea/PlaceholderPanel,
	"journal": $ContentArea/JournalPanel,
	"encyclopedia": $ContentArea/PlaceholderPanel,
	"map": $ContentArea/PlaceholderPanel,
}

@onready var _inventory_stats: StatsColumn = $ContentArea/InventoryPanel/StatsColumn
@onready var _character_stats: StatsColumn = $ContentArea/CharacterPanel/StatsColumn

@onready var _portrait: TextureRect = $ContentArea/InventoryPanel/EquipmentColumn/VBoxContainer/PortraitRow/Portrait
@onready var _sort_button: Button = $ContentArea/InventoryPanel/InventoryColumn/VBoxContainer/SortButton
@onready var _inventory: Inventory = $ContentArea/InventoryPanel/InventoryColumn/VBoxContainer/Inventory

## All 16 shared equip slots, built once so _swap_equipment() doesn't
## need to re-walk the tree every unit switch — same "gather named nodes
## once" style _alignment_cells already uses.
@onready var _equip_slots: Array[EquipSlot] = [
	$ContentArea/InventoryPanel/EquipmentColumn/VBoxContainer/PortraitRow/LeftSlots/Helmet,
	$ContentArea/InventoryPanel/EquipmentColumn/VBoxContainer/PortraitRow/LeftSlots/Amulet,
	$ContentArea/InventoryPanel/EquipmentColumn/VBoxContainer/PortraitRow/LeftSlots/Cloak,
	$ContentArea/InventoryPanel/EquipmentColumn/VBoxContainer/PortraitRow/LeftSlots/ChestArmor,
	$ContentArea/InventoryPanel/EquipmentColumn/VBoxContainer/PortraitRow/LeftSlots/Undershirt,
	$ContentArea/InventoryPanel/EquipmentColumn/VBoxContainer/PortraitRow/LeftSlots/Bracers,
	$ContentArea/InventoryPanel/EquipmentColumn/VBoxContainer/PortraitRow/RightSlots/Ring1,
	$ContentArea/InventoryPanel/EquipmentColumn/VBoxContainer/PortraitRow/RightSlots/Ring2,
	$ContentArea/InventoryPanel/EquipmentColumn/VBoxContainer/PortraitRow/RightSlots/Gloves,
	$ContentArea/InventoryPanel/EquipmentColumn/VBoxContainer/PortraitRow/RightSlots/Belt,
	$ContentArea/InventoryPanel/EquipmentColumn/VBoxContainer/PortraitRow/RightSlots/Legs,
	$ContentArea/InventoryPanel/EquipmentColumn/VBoxContainer/PortraitRow/RightSlots/Boots,
	$ContentArea/InventoryPanel/EquipmentColumn/VBoxContainer/WeaponSetsRow/MeleeSet/Slots/MeleeMainHand,
	$ContentArea/InventoryPanel/EquipmentColumn/VBoxContainer/WeaponSetsRow/MeleeSet/Slots/MeleeOffHand,
	$ContentArea/InventoryPanel/EquipmentColumn/VBoxContainer/WeaponSetsRow/RangedSet/Slots/RangedMainHand,
	$ContentArea/InventoryPanel/EquipmentColumn/VBoxContainer/WeaponSetsRow/RangedSet/Slots/RangedOffHand,
]

## (alignment_category, tendency_category) -> display title, matching
## Unit.alignment_category()/tendency_category()'s -1/0/1 output exactly
## so this never needs its own copy of the threshold logic. Tendency
## reads as a modifier on alignment ("Dark Chaos", not "Chaotic Dark"),
## so it leads and alignment takes its noun form (Chaos/Law, not
## Chaotic/Lawful) instead of the adjective form used elsewhere.
const _ALIGNMENT_TITLES: Dictionary = {
	Vector2i(-1, 1): "Light Chaos", Vector2i(0, 1): "Light Neutral", Vector2i(1, 1): "Light Law",
	Vector2i(-1, 0): "Neutral Chaos", Vector2i(0, 0): "True Neutral", Vector2i(1, 0): "Neutral Law",
	Vector2i(-1, -1): "Dark Chaos", Vector2i(0, -1): "Dark Neutral", Vector2i(1, -1): "Dark Law",
}

@onready var _alignment_title: Label = $ContentArea/CharacterPanel/AlignmentColumn/VBoxContainer/AlignmentTitle
@onready var _alignment_grid: AlignmentGrid = $ContentArea/CharacterPanel/AlignmentColumn/VBoxContainer/AlignmentGrid

@onready var _skill_list: VBoxContainer = $ContentArea/CharacterPanel/SkillColumn/VBoxContainer/ScrollContainer/SkillList

@onready var _demon_panel: DemonCompendiumPanel = $ContentArea/DemonPanel

@onready var _quest_list: ItemList = $ContentArea/JournalPanel/MarginContainer/HBoxContainer/QuestListMargin/QuestListVBox/QuestList
@onready var _quest_detail_title: Label = $ContentArea/JournalPanel/MarginContainer/HBoxContainer/QuestDetailMargin/QuestDetailVBox/DetailTitle
@onready var _quest_detail_list: VBoxContainer = $ContentArea/JournalPanel/MarginContainer/HBoxContainer/QuestDetailMargin/QuestDetailVBox/ScrollContainer/DetailList

var _unit: Unit = null
## _quest_list's items are just text/index — this is the actual Quest
## each row refers to, index-for-index, so a click on row i can look up
## _journal_quests[i] without QuestDatabase needing to expose "the Nth
## quest" as a concept of its own.
var _journal_quests: Array[Quest] = []


func _ready() -> void:
	visible = false
	# So a Resource with no scene-tree position of its own (GiveItemEffect)
	# can still find its way to the party's shared inventory — see that
	# file's header for why a group, not a direct reference.
	add_to_group("party_overview")

	for tab_name in _tab_buttons:
		_tab_buttons[tab_name].pressed.connect(_show_tab.bind(tab_name))
	$TopBar/CloseButton.pressed.connect(func(): visible = false)
	_sort_button.pressed.connect(_inventory.sort_items)
	_quest_list.item_selected.connect(_on_quest_selected)

	_show_tab("inventory")


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("open_party_overview") or DialogueManager.is_active() or StashManager.is_active():
		return

	if visible:
		visible = false
		return

	var unit: Unit = PlayerInteractionState.get_active_unit()
	if unit:
		open_for(unit)


## Lets StashPanel borrow the party's shared Inventory node while a chest
## is open (see stash_panel.gd) — reparented out and back rather than a
## second Inventory instance, so there's only ever one real set of items.
func get_inventory() -> Inventory:
	return _inventory


## Where get_inventory()'s node belongs when nothing has borrowed it —
## StashPanel reparents it back here on close.
func get_inventory_slot() -> VBoxContainer:
	return $ContentArea/InventoryPanel/InventoryColumn/VBoxContainer


func open_for(unit: Unit) -> void:
	_swap_equipment(unit)
	_unit = unit
	_inventory_stats.refresh(unit)
	_character_stats.refresh(unit)
	_portrait.texture = unit.portrait_texture
	_refresh_alignment_grid(unit)
	_refresh_skill_list(unit)
	_refresh_journal_list()
	_demon_panel.refresh()
	visible = true
	_show_tab("inventory")


## Reparents the outgoing unit's (self._unit, still the OLD value at
## this point) equipped items out to ITS OWN storage, and the incoming
## unit's already-equipped items in — via EquipSlot.display_item()/
## clear_display(), the visual-only pair, NOT equip()/unequip(), so
## nothing gets re-registered or reverted just because it became
## visible/invisible. See Unit._equipped_items_home's header for why
## visibility is toggled explicitly here.
func _swap_equipment(unit: Unit) -> void:
	var previous_unit: Unit = _unit
	for slot in _equip_slots:
		if previous_unit and slot.equipped_item:
			var item: Item = slot.equipped_item
			item.reparent(previous_unit.get_equipped_items_home())
			item.visible = false
			slot.clear_display()

		slot.unit = unit
		var stored_item: Item = unit.get_equipped_item(slot.slot)
		if stored_item:
			stored_item.visible = true
			slot.display_item(stored_item)


func _show_tab(tab_name: String) -> void:
	for panel in _panels.values():
		panel.visible = false
	_panels[tab_name].visible = true

	for key in _tab_buttons:
		_tab_buttons[key].disabled = (key == tab_name)


func _refresh_alignment_grid(unit: Unit) -> void:
	var category: Vector2i = Vector2i(unit.alignment_category(), unit.tendency_category())
	_alignment_title.text = _ALIGNMENT_TITLES.get(category, "True Neutral")
	_alignment_grid.set_alignment(unit.alignment, unit.tendency)


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


## Unlike _refresh_skill_list/_refresh_alignment_grid, takes no unit — a
## quest's progress is FlagManager world state, not per-character, so
## the Journal reads the same regardless of which party member's
## overview is open (the same "which unit is asking doesn't change the
## answer" reason FlagPrerequisite ignores its own unit argument).
##
## Left/right master-detail split (ItemList + a separate detail pane),
## matching how quest journals actually read elsewhere (a list of
## quests, and the full step-by-step log for whichever one is
## selected) rather than one flat list of single-line summaries. No
## quest-chain grouping or a "show completed" filter yet — this project
## has exactly one quest right now, so building either would be guessing
## at a shape with nothing real to guess from; add them once a second
## quest actually makes flat-list-of-one-quest feel cramped.
func _refresh_journal_list() -> void:
	_quest_list.clear()
	_journal_quests.clear()

	for quest in QuestDatabase.get_all():
		if not quest.is_started():
			continue
		_journal_quests.append(quest)
		_quest_list.add_item(quest.title + ("  (Complete)" if quest.is_complete() else ""))

	if _journal_quests.is_empty():
		_show_quest_detail(null)
		return

	_quest_list.select(0)
	_show_quest_detail(_journal_quests[0])


func _on_quest_selected(index: int) -> void:
	_show_quest_detail(_journal_quests[index])


## quest is null for the "nothing started yet" empty state — shows a
## dimmed placeholder in the detail pane instead of leaving it stuck on
## whatever the previously-open character's Journal last selected.
func _show_quest_detail(quest: Quest) -> void:
	for child in _quest_detail_list.get_children():
		child.queue_free()

	if not quest:
		_quest_detail_title.text = ""
		var empty_label := Label.new()
		empty_label.modulate = Color(1, 1, 1, 0.5)
		empty_label.text = "No quests yet."
		_quest_detail_list.add_child(empty_label)
		return

	_quest_detail_title.text = quest.title + ("  (Complete)" if quest.is_complete() else "")

	var reached: Array[QuestStage] = quest.reached_stages()
	for i in reached.size():
		var stage: QuestStage = reached[i]
		var is_current: bool = i == reached.size() - 1

		var entry := VBoxContainer.new()
		entry.add_theme_constant_override("separation", 2)
		# Earlier stages read as history once superseded — only the
		# current (latest-reached) one stays at full brightness, same
		# "what's active vs. what's done" distinction a real quest log
		# marks with an icon; a dim/bright split is the simplest version
		# of that with plain Labels, no new art needed.
		if not is_current:
			entry.modulate = Color(1, 1, 1, 0.6)

		var text_label := Label.new()
		text_label.text = stage.journal_text
		text_label.autowrap_mode = TextServer.AUTOWRAP_WORD

		entry.add_child(text_label)
		_quest_detail_list.add_child(entry)
