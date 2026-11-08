class_name PartyOverview
extends UIScreen
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
## The Inventory tab's party rail (one button per PartyManager.members,
## demons excluded) and Q/E switch the shown member without closing:
## show_unit() re-points everything, and _swap_equipment() below re-points
## the 16 shared EquipSlots at the incoming unit and rebuilds their widgets
## from what it wears (equipment persists per unit, see UnitEquipment).
## The bag is the party's, so it stays; its All/Gear/Use/Runes buttons
## only dim what doesn't match (Inventory.set_filter).
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
##
## blocks_input_below=true is authored on this scene's instance in
## MainRoot.tscn (see UIScreen's own header) — what makes UIStack.
## can_open() correctly refuse a new C-key open while a stash is up,
## replacing the old hand-rolled "is a dialogue or a stash active"
## guard this file used to check directly.
## hides_hud/closes_on_cancel stay at UIScreen's own defaults.

@onready var _tab_buttons: Dictionary = {
	"inventory": %TabInventory,
	"character": %TabCharacter,
	"demons": %TabDemons,
	"spawn": %TabSpawn,
	"music": %TabMusic,
	"alignment": %TabAlignment,
	"spellbook": %TabSpellbook,
	"journal": %TabJournal,
	"encyclopedia": %TabEncyclopedia,
	"map": %TabMap,
}
@onready var _panels: Dictionary = {
	"inventory": %InventoryPanel,
	"character": %CharacterPanel,
	"demons": %DemonPanel,
	"spawn": %SpawnPanel,
	"music": %MusicPanel,
	"alignment": %AlignmentPanel,
	"spellbook": %PlaceholderPanel,
	"journal": %JournalPanel,
	"encyclopedia": %PlaceholderPanel,
	"map": %PlaceholderPanel,
}

## Left as plain NodePaths, not %UniqueName — both StatsColumn instances
## share their sub-scene's own default root name, so marking both unique
## within THIS scene would collide (see stats_column.tscn's own 15
## fields for the ones that WERE safe to convert: each of those is
## scoped to its own instance's independent unique-name namespace,
## unlike these two outer references, which are scoped to this scene).
@onready var _inventory_stats: StatsColumn = $ContentArea/InventoryPanel/StatsColumn
@onready var _character_stats: StatsColumn = $ContentArea/CharacterPanel/StatsColumn

@onready var _portrait: TextureRect = %Portrait
@onready var _encumbrance_bar: EncumbranceBar = %EncumbranceBar
@onready var _sort_button: Button = %SortButton
@onready var _inventory: Inventory = %Inventory
@onready var _gold_label: Label = %GoldLabel
@onready var _debug_add_gold_button: Button = %DebugAddGoldButton
@onready var _debug_add_xp_button: Button = %DebugAddXpButton
@onready var _level_up_toast: PanelContainer = %LevelUpToast
@onready var _level_up_title: Label = %LevelUpTitle
@onready var _level_up_note: Label = %LevelUpNote
@onready var _level_up_button: Button = %LevelUpButton
@onready var _party_list: VBoxContainer = %PartyList

const RAIL_BUTTON_SIZE := Vector2(72, 88)
const RAIL_SHOWN := Color(0.851, 0.722, 0.31, 1)
const RAIL_OTHER := Color(0.227, 0.239, 0.275, 1)
const RAIL_HP := Color(0.788, 0.29, 0.29, 1)

## Filter button -> what it lets through, at full brightness.
@onready var _bag_filters: Dictionary = {
	%FilterAll: func(_i: ItemInstance) -> bool: return true,
	%FilterGear: func(i: ItemInstance) -> bool: return i.gear_data != null,
	%FilterUse: func(i: ItemInstance) -> bool: return i.gear_data == null and not (i.definition is RuneItem),
	%FilterRunes: func(i: ItemInstance) -> bool: return i.definition is RuneItem,
}

## All 16 shared equip slots, built once so _swap_equipment() doesn't
## need to re-walk the tree every unit switch — same "gather named nodes
## once" style _alignment_cells already uses.
@onready var _equip_slots: Array[EquipSlot] = [
	%Helmet,
	%Amulet,
	%Cloak,
	%ChestArmor,
	%Undershirt,
	%Bracers,
	%Ring1,
	%Ring2,
	%Gloves,
	%Belt,
	%Legs,
	%Boots,
	%MeleeMainHand,
	%MeleeOffHand,
	%RangedMainHand,
	%RangedOffHand,
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

@onready var _alignment_title: Label = %AlignmentTitle
@onready var _alignment_grid: AlignmentGrid = %AlignmentGrid

@onready var _skill_list: VBoxContainer = %SkillList

@onready var _ability_list: VBoxContainer = %AbilityList
@onready var _debug_grant_section: VBoxContainer = %DebugGrantSection
@onready var _grant_ability_list: ItemList = %GrantAbilityList
@onready var _grant_ability_button: Button = %GrantAbilityButton
## Index-for-index with _grant_ability_list's rows — same "the list item
## is just text, this array is the real reference" convention
## DemonCompendiumPanel's own _grant_species already uses.
var _grantable_abilities: Array[Ability] = []

@onready var _demon_panel: DemonCompendiumPanel = %DemonPanel
@onready var _spawn_panel: DebugSpawnPanel = %SpawnPanel
@onready var _music_panel: DebugMusicPanel = %MusicPanel
@onready var _alignment_panel: DebugAlignmentPanel = %AlignmentPanel

@onready var _quest_list: ItemList = %QuestList
@onready var _quest_detail_title: Label = %DetailTitle
@onready var _quest_detail_list: VBoxContainer = %DetailList

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

	# The party's items live in PartyManager.inventory, which also saves
	# them; this widget only draws that container.
	_inventory.bind(PartyManager.inventory)

	for tab_name in _tab_buttons:
		_tab_buttons[tab_name].pressed.connect(_show_tab.bind(tab_name))
	%TabSpawn.visible = OS.is_debug_build()
	%TabMusic.visible = OS.is_debug_build()
	%TabAlignment.visible = OS.is_debug_build()
	%CloseButton.pressed.connect(close)
	_sort_button.pressed.connect(_inventory.sort_items)
	for button in _bag_filters:
		button.pressed.connect(func(): _inventory.set_filter(_bag_filters[button]))
	PartyManager.member_added.connect(func(_u): _refresh_party_rail())
	PartyManager.member_removed.connect(func(_u): _refresh_party_rail())
	_quest_list.item_selected.connect(_on_quest_selected)

	_debug_add_gold_button.visible = OS.is_debug_build()
	_debug_add_gold_button.pressed.connect(func(): CurrencyManager.add_gold(50))
	CurrencyManager.gold_changed.connect(_on_gold_changed)
	_on_gold_changed(CurrencyManager.gold)

	_debug_add_xp_button.visible = OS.is_debug_build()
	_debug_add_xp_button.pressed.connect(func(): Progression.award_xp(100, "debug"))
	_level_up_button.pressed.connect(_on_level_up_pressed)
	Progression.xp_changed.connect(func(_xp, _level): _on_xp_changed())
	Progression.points_changed.connect(func(_id): _refresh_level_toast())
	%CharacterPanel.visibility_changed.connect(_refresh_level_toast)

	_debug_grant_section.visible = OS.is_debug_build()
	if OS.is_debug_build():
		_grantable_abilities = AbilityDatabase.get_all()
		for ability in _grantable_abilities:
			_grant_ability_list.add_item(ability.ability_name)
		_grant_ability_button.pressed.connect(_on_grant_ability_pressed)

	_show_tab("inventory")


func _unhandled_input(event: InputEvent) -> void:
	# The cameras leave Q/E alone while this is open (UIStack.can_open()).
	if UIStack.is_open(self) and _unit:
		var step := -1 if event.is_action_pressed("camera_rotate_left") else 				(1 if event.is_action_pressed("camera_rotate_right") else 0)
		if step != 0:
			_cycle_member(step)
			get_viewport().set_input_as_handled()
			return

	if not event.is_action_pressed("open_party_overview"):
		return

	if UIStack.is_open(self):
		close()
		return

	if not UIStack.can_open():
		return

	var unit: Unit = PlayerInteractionState.get_active_unit()
	if unit:
		open_for(unit)
	elif OS.is_debug_build():
		# No active Unit at all means the overworld (see
		# PlayerInteractionState) — the one place Alignment is actually
		# the tab worth landing on, since it's also the only tab here
		# that has anything to show with no live Unit to open on.
		_alignment_panel.refresh()
		open()
		_show_tab("alignment")


## Lets StashPanel borrow the party's shared Inventory node while a chest
## is open (see stash_panel.gd) — reparented out and back rather than a
## second Inventory instance, so there's only ever one real set of items.
## Equipping, or socketing a rune into something worn, changes the
## shown unit's stats while the sheet is open.
func _on_equipment_changed(unit: Unit) -> void:
	_inventory_stats.refresh(unit)
	_encumbrance_bar.refresh(unit)
	_character_stats.refresh(unit)


func get_inventory() -> Inventory:
	return _inventory


## Where get_inventory()'s node belongs when nothing has borrowed it —
## StashPanel reparents it back here on close.
func get_inventory_slot() -> VBoxContainer:
	return %BagSlot


func open_for(unit: Unit) -> void:
	show_unit(unit)
	_refresh_party_rail()
	open()
	_show_tab("inventory")


## Points every tab at unit, staying on whichever tab is showing.
func show_unit(unit: Unit) -> void:
	_swap_equipment(unit)
	if is_instance_valid(_unit) and _unit.equipment_changed.is_connected(_on_equipment_changed):
		_unit.equipment_changed.disconnect(_on_equipment_changed)
	_unit = unit
	unit.equipment_changed.connect(_on_equipment_changed)
	_inventory_stats.refresh(unit)
	_encumbrance_bar.refresh(unit)
	_character_stats.refresh(unit)
	_portrait.texture = unit.portrait_texture
	_refresh_alignment_grid(unit)
	_refresh_skill_list(unit)
	_refresh_ability_list(unit)
	_refresh_level_toast()
	_refresh_journal_list()
	_demon_panel.refresh()
	_spawn_panel.refresh()
	_music_panel.refresh()
	_alignment_panel.refresh()
	_highlight_rail()


## Next (step 1) or previous (-1) party member, wrapping.
func _cycle_member(step: int) -> void:
	var members: Array[Unit] = PartyManager.members
	if members.is_empty():
		return
	var index := members.find(_unit)
	show_unit(members[posmod(index + step, members.size())])


## Rebuilt on open and when the party changes; a switch only moves the
## highlight. Out of the list at once: a queued-free button would still
## count toward the rail's height, and an anchored rail never shrinks back.
func _refresh_party_rail() -> void:
	for child in _party_list.get_children():
		_party_list.remove_child(child)
		child.queue_free()
	for member in PartyManager.members:
		_party_list.add_child(_rail_button(member))
	_highlight_rail()


func _highlight_rail() -> void:
	for button in _party_list.get_children():
		var frame: StyleBoxFlat = button.get_theme_stylebox("normal")
		frame.border_color = RAIL_SHOWN if button.get_meta("unit") == _unit else RAIL_OTHER


## Portrait and name, an HP bar under it, gold-framed for the shown unit.
func _rail_button(member: Unit) -> Button:
	var button := Button.new()
	button.custom_minimum_size = RAIL_BUTTON_SIZE
	button.focus_mode = Control.FOCUS_NONE
	button.tooltip_text = member.get_display_name()
	var frame := StyleBoxFlat.new()
	frame.bg_color = Color(0.118, 0.125, 0.153, 1)
	frame.set_corner_radius_all(6)
	frame.set_border_width_all(2)
	for state in ["normal", "hover", "pressed", "focus"]:
		button.add_theme_stylebox_override(state, frame)
	button.set_meta("unit", member)
	button.pressed.connect(show_unit.bind(member))

	var art := TextureRect.new()
	art.texture = member.portrait_texture
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(art)
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 2)

	var name_label := Label.new()
	name_label.text = member.get_display_name()
	name_label.add_theme_font_size_override("font_size", 13)
	name_label.add_theme_constant_override("outline_size", 4)
	name_label.add_theme_color_override("font_outline_color", Color.BLACK)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(name_label)
	name_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE, Control.PRESET_MODE_MINSIZE, 4)

	var max_hp: float = member.get_stat(StatIds.HP)
	var hp := ColorRect.new()
	hp.color = RAIL_HP
	hp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(hp)
	hp.anchor_top = 1.0
	hp.anchor_bottom = 1.0
	hp.anchor_right = clampf(member.get_pool(StatIds.HP) / max_hp, 0.0, 1.0) if max_hp > 0 else 0.0
	hp.offset_top = 3
	hp.offset_bottom = 7
	return button


## Re-points the 16 shared EquipSlots at unit and shows what it wears —
## via EquipSlot.display_instance()/clear_display(), the visual-only pair,
## NOT equip()/unequip(), so nothing gets re-registered or reverted just
## because it became visible/invisible. The worn instances live on each
## unit (UnitEquipment); the widgets are rebuilt every time.
func _swap_equipment(unit: Unit) -> void:
	for slot in _equip_slots:
		slot.clear_display()
		slot.unit = unit
		slot.display_instance(unit.get_equipped_item(slot.slot))


## Opens this screen already showing one tab, for a caller that knows
## which part of it the player asked for — the Cathedral's Fuse option
## wants the demons tab, not whatever was last looked at.
func open_on_tab(tab_name: String) -> void:
	open()
	_show_tab(tab_name)


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


## Both stat columns draw the party's XP bar.
func _on_xp_changed() -> void:
	if is_instance_valid(_unit):
		_inventory_stats.refresh(_unit)
		_character_stats.refresh(_unit)
	_refresh_level_toast()


## A toast on the Character tab while the member shown has points left:
## what is left to spend, and LEVEL UP. It stays until they are spent
## (the world toast only reaches the leader; this reaches anyone), and
## fades in each time it comes into view.
func _refresh_level_toast() -> void:
	var points: Dictionary = Progression.unspent(_unit) if is_instance_valid(_unit) else {}
	var wanted: bool = is_instance_valid(_unit) and Progression.has_unspent(_unit)
	var was_shown: bool = _level_up_toast.is_visible_in_tree()
	_level_up_toast.visible = wanted
	if not wanted:
		return
	_level_up_title.text = "LEVEL %d" % Progression.level
	var parts: PackedStringArray = []
	for entry in [[Progression.ATTRIBUTES, "attribute point"], [Progression.SKILLS, "skill point"],
			[Progression.ABILITIES, "ability pick"]]:
		var count: int = points.get(entry[0], 0)
		if count > 0:
			parts.append("%d %s%s" % [count, entry[1], "" if count == 1 else "s"])
	_level_up_note.text = "%s to spend" % "  ·  ".join(parts)
	if not was_shown and _level_up_toast.is_visible_in_tree():
		_level_up_toast.modulate.a = 0.0
		create_tween().tween_property(_level_up_toast, "modulate:a", 1.0, 0.3)


## The level-up screen opens over the world, not over this one, so this
## closes first (UIStack.can_open() is false while it is up). A refusal
## ("Not during a fight.") brings this back with the reason on the toast.
func _on_level_up_pressed() -> void:
	var unit: Unit = _unit
	close()
	var why: String = Progression.open_level_up(unit)
	if not why.is_empty():
		open_for(unit)
		_show_tab("character")
		_level_up_note.text = why


func _refresh_ability_list(unit: Unit) -> void:
	for child in _ability_list.get_children():
		child.queue_free()

	if unit.abilities.is_empty():
		var empty_label := Label.new()
		empty_label.modulate = Color(1, 1, 1, 0.5)
		empty_label.text = "No abilities."
		_ability_list.add_child(empty_label)
		return

	for ability in unit.abilities:
		var label := Label.new()
		label.text = ability.ability_name if ability else "(unknown)"
		_ability_list.add_child(label)


## Appends to the unit's own abilities array — every unit's ability list
## is already a plain per-instance Array[Ability] (see Unit.abilities),
## so "grant an ability" needs nothing more than this; there's no
## separate registration step the way summoning/skills have. Refreshes
## the read-only list above immediately so the grant is visible without
## reopening the sheet, same "the debug action's effect should be
## immediately observable" standard DemonCompendiumPanel's own grant
## button already holds itself to.
func _on_grant_ability_pressed() -> void:
	if not _unit:
		return
	var selected: PackedInt32Array = _grant_ability_list.get_selected_items()
	if selected.is_empty():
		return
	_unit.add_ability(_grantable_abilities[selected[0]])
	_refresh_ability_list(_unit)


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


func _on_gold_changed(new_amount: int) -> void:
	_gold_label.text = "%d g" % new_amount
