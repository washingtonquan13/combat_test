extends UIScreen
## Character creation — building the player's own character (the future
## party leader, "THE MAIN CHARACTER" per the roadmap this was scoped
## against), via the point-buy tables verified for Buckets A (attributes)
## and C (skills), plus a portrait pick. Bucket B is deliberately not
## part of this — see PointBuyTable's own header for why.
##
## Tab-based (a plain TabContainer — matches this project's own "prefer
## built-in Godot mechanisms" stance rather than hand-rolling a page
## switcher), specifically so adding a 5th/6th tab later (background,
## starting gear, ...) is just another TabContainer child, not a
## reflow of an ever-more-crowded single screen. Back/Confirm live
## OUTSIDE the tabs, at the bottom, since Confirm's validity depends on
## every tab at once regardless of which one is currently showing.
## For the same reason a character sheet (portrait, name, attribute
## summary, a checklist of what Confirm is waiting for) sits beside the
## tabs and stays visible whichever tab is open; its derived-stats line
## follows the attribute steppers through StatDatabase, the same formulas
## the spawned unit uses. Which attributes are bought is data too: every
## stat file with a point_buy table gets a row. The Origin tab is a deliberate placeholder:
## disabled controls laid out for choices that are not built yet. The DEBUG
## Auto-Fill/Quick Create buttons show in debug builds only.
##
## A UIScreen living permanently under MainRoot's CanvasLayer, NOT a
## world — same reasoning as main_menu.gd's own header. Reached from the
## title screen's Start button; Confirm is the one place in the whole
## front end that actually loads a world, because that's the moment the
## game proper begins. If a 3D framing set for the character being built
## is ever wanted (BG3 stands yours on a plinth), that's an ordinary
## backdrop world loaded underneath this screen, not a replacement for it.
##
## On Confirm, a real Unit can't be built yet — there's no arena loaded
## to place it in — so the result is written into PartyManager.
## pending_leader as a plain PartyMemberData instead, and whichever world
## first spawns (test_arena.gd's own _build_leader(), today) consumes it.
##
## Persistent across visits — this screen is instanced once under
## MainRoot's CanvasLayer and never rebuilt — but it resets to a blank
## form every time it becomes visible (see reset() below), not just
## once at boot. Without that, all of a previous build's state
## (_attribute_values, _skill_values, the name field, the portrait
## selection/preview, the open tab) stayed exactly as the last visit
## left it, and _update_confirm_state() recomputed off that stale data
## and left BEGIN ADVENTURE enabled — one click from silently
## re-committing the PREVIOUS character. Follows the same reset-on-show
## idiom main_menu.gd/esc_menu.gd/stash_panel.gd's own visibility_changed
## handlers already use. This still does NOT read PartyManager.
## pending_leader back in to pre-fill on open — this screen's only
## contact with PartyManager stays writing to it on Confirm.
##
## LEVEL-UP MODE (open_level_up): the same screen, reopened on a party
## member who has unspent points from Progression — but D&D-style plain
## points, not point-buy: every +1 costs 1, whatever the value, so the
## cost tables only set the caps. Each row's floor is the member's
## current value, so nothing already bought can be sold back, and the
## pool is what that member has unspent rather than the table's
## point_pool. Origin, Portrait and the name are fixed by then and
## hidden; an Abilities tab appears instead — the ONLY place abilities
## are bought (a new character starts with just the basics). Confirm
## writes onto the live Unit and hands back what was spent; whatever was
## not spent stays with Progression for next time. Back cancels and
## changes nothing. The mode ends when the screen closes.

## The one budget every bought stat is spent from. Each bought stat's
## file names this same table as its point_buy; a stat naming a different
## one would need its own pool, which nothing here supports yet.
const ATTRIBUTE_TABLE: PointBuyTable = preload("res://data/character_creation/attribute_costs.tres")
const SKILL_TABLE: PointBuyTable = preload("res://data/character_creation/skill_costs.tres")

## Matches unit_portrait.tscn's own authored ratio exactly (80x100) —
## see that scene for why: a TextureRect using expand_mode=EXPAND_IGNORE_
## SIZE + stretch_mode=STRETCH_KEEP_ASPECT_COVERED inside a Control held
## to this ratio is what makes an arbitrarily-sized source image crop
## to fill it consistently, the same way the initiative strip/party
## panel already do. Grid thumbnails and the preview box are just
## different absolute scales of the same 4:5 shape, not two different
## crops.
const PORTRAIT_ASPECT_RATIO: Vector2 = Vector2(80, 100)
const PORTRAIT_GRID_CELL_SCALE: float = 0.8  # 64x80
const PORTRAIT_PREVIEW_SCALE: float = 2.0  # 160x200
const PORTRAITS_DIR: String = "res://assets/portraits/"
const PORTRAIT_EXTENSIONS: Array[String] = ["jpg", "jpeg", "png"]

const POINT_BUY_ROW: PackedScene = preload("res://systems/character_creation_system/point_buy_row.tscn")

## Each skill's "DX/A" tag — the difficulty letters are GURPS's.
const DIFFICULTY_TAGS: Dictionary = {
	Skill.Difficulty.EASY: "E",
	Skill.Difficulty.AVERAGE: "A",
	Skill.Difficulty.HARD: "H",
	Skill.Difficulty.VERY_HARD: "VH",
}

## What the debug fill spends skill points on, round-robin. Any name not
## in SkillDatabase is skipped, and an empty result falls back to every
## skill, so renaming a skill degrades this to a different build rather
## than breaking it.
const QUICK_CREATE_SKILLS: Array[String] = ["Basic Attack", "Athletics", "Perception", "Stealth", "Persuasion"]
const QUICK_CREATE_NAME: String = "Debug Hero"

@onready var _tabs: TabContainer = %Tabs
@onready var _name_edit: LineEdit = %NameEdit
@onready var _portrait_grid: GridContainer = %PortraitGrid
@onready var _preview_texture: TextureRect = %PreviewTexture
@onready var _portrait_placeholder: Control = %PortraitPlaceholder
@onready var _attribute_summary: Label = %AttributeSummary
@onready var _derived_summary: Label = %DerivedSummary
@onready var _checklist: Label = %Checklist
@onready var _debug_tools: Control = %DebugTools
@onready var _attributes_header: Label = %AttributesHeader
@onready var _attributes_list: VBoxContainer = %AttributesList
@onready var _skills_header: Label = %SkillsHeader
@onready var _skills_list: VBoxContainer = %SkillsList
@onready var _confirm_button: Button = %ConfirmButton
@onready var _back_button: Button = %BackButton
@onready var _title: Label = %Title
@onready var _abilities_header: Label = %AbilitiesHeader
@onready var _abilities_list: VBoxContainer = %AbilitiesList

## Tab indices, as the .tscn orders them.
const TAB_ORIGIN: int = 0
const TAB_PORTRAIT: int = 1
const TAB_ATTRIBUTES: int = 2
const TAB_ABILITIES: int = 4

## Stat ids with a point_buy table, in display order — the rows.
var _attribute_ids: Array[String] = []
var _attribute_values: Dictionary = {}  # String (stat id) -> int
var _skill_values: Dictionary = {}  # String (skill name) -> int (relative level)
var _attribute_rows: Dictionary = {}  # String -> Dictionary (row's own widgets)
var _skill_rows: Dictionary = {}
var _portrait_buttons: Dictionary = {}  # String (res:// path) -> Button, for selection highlighting
var _selected_portrait_path: String = ""

## Level-up mode: the member being levelled, or null when creating.
var _level_up_unit: Unit = null
## Each row's value when the screen opened — the floor of its "-".
var _floor_attributes: Dictionary = {}  # String -> int
var _floor_skills: Dictionary = {}  # String -> int
## Progression.unspent(_level_up_unit), read once on open.
var _points: Dictionary = {}
var _picked_abilities: Array[Ability] = []
var _ability_boxes: Dictionary = {}  # Ability -> CheckBox


func _enter_tree() -> void:
	# So main_menu.gd's Start can find this screen without holding a
	# NodePath to it — same find-by-role idiom party_overview/
	# conversation_log/esc_menu already use. In _enter_tree rather than
	# _ready so it's discoverable regardless of sibling _ready order.
	add_to_group("character_creation")


func _ready() -> void:
	# Structural, one-time only: builds the rows/grid and connects their
	# +/-/portrait pressed signals. Must NOT live in reset() — reset() runs
	# on every open, and re-running this would double-connect every one of
	# those signals (or duplicate the rows/buttons outright).
	for definition in StatDatabase.get_bought():
		var id: String = String(definition.id)
		_attribute_ids.append(id)
		_build_row(_attributes_list, definition.display_name, definition.abbreviation, definition.description, id, _attribute_rows, _on_attribute_step)

	for skill in SkillDatabase.get_all():
		var tag: String = "%s/%s" % [skill.controlling_attribute, DIFFICULTY_TAGS.get(skill.difficulty_level, "?")]
		_build_row(_skills_list, skill.skill_name, tag, skill.description, skill.skill_name, _skill_rows, _on_skill_step)

	# Debug builds only (editor runs and debug exports): a release build
	# must not be able to skip character creation.
	_debug_tools.visible = OS.is_debug_build()

	_build_portrait_grid()

	# Same reset-on-show idiom as main_menu.gd/esc_menu.gd/stash_panel.gd's
	# own visibility_changed handlers — see this file's header for why a
	# once-at-boot _ready() seed alone isn't enough.
	visibility_changed.connect(_on_visibility_changed)

	# SaveManager.new_game_started is landing in parallel elsewhere in this
	# codebase; guarded both ways (has_signal here, is_connected in
	# _exit_tree) so this file parses and runs whether or not that signal
	# exists yet, and so this persistent screen doesn't leak a connection
	# to an autoload after being freed — see the recorded RefCounted-
	# component/autoload-signal-leak bug class in project memory.
	if SaveManager.has_signal("new_game_started"):
		SaveManager.new_game_started.connect(_on_new_game_started)

	reset()


## Restores every piece of this screen's state to its boot default —
## called once from _ready() (after the structural setup above) and again
## every time the screen becomes visible (_on_visibility_changed below),
## so a second open never shows the previous visit's build. Only ever
## ASSIGNS state; never connects a signal or creates a node — those are
## _ready()'s job, exactly once.
func reset() -> void:
	if not is_instance_valid(_level_up_unit):
		_level_up_unit = null
	var levelling: bool = _level_up_unit != null
	_tabs.set_tab_hidden(TAB_ORIGIN, levelling)
	_tabs.set_tab_hidden(TAB_PORTRAIT, levelling)
	_tabs.set_tab_hidden(TAB_ABILITIES, not levelling)
	_name_edit.editable = not levelling
	_debug_tools.visible = OS.is_debug_build() and not levelling
	_back_button.text = "CANCEL" if levelling else "BACK"
	_confirm_button.text = "LEVEL UP" if levelling else "BEGIN ADVENTURE"
	_floor_attributes.clear()
	_floor_skills.clear()
	_picked_abilities.clear()
	if levelling:
		_reset_level_up()
	else:
		_reset_create()
	# Recomputes every row's label/cost/disabled state off the values just
	# reset above, and _update_confirm_state() off all of it together —
	# same refresh calls _on_attribute_step/_on_skill_step already use, so
	# there's no separate "blank state" rendering path to keep in sync.
	_refresh_attributes()
	_refresh_skills()
	_refresh_abilities()
	_update_confirm_state()


func _reset_create() -> void:
	_title.text = "CREATE YOUR CHARACTER"
	_points.clear()
	_name_edit.text = ""

	for id in _attribute_ids:
		_attribute_values[id] = ATTRIBUTE_TABLE.default_value

	for skill in SkillDatabase.get_all():
		_skill_values[skill.skill_name] = SKILL_TABLE.default_value

	if _selected_portrait_path in _portrait_buttons:
		_portrait_buttons[_selected_portrait_path].button_pressed = false
	_selected_portrait_path = ""
	_preview_texture.texture = null
	_portrait_placeholder.visible = true

	_tabs.current_tab = TAB_ORIGIN


## The member as they stand: every row starts at, and cannot go below,
## its current value. The ability list is rebuilt here, not in _ready,
## because what is left to learn depends on who is levelling.
func _reset_level_up() -> void:
	var unit: Unit = _level_up_unit
	_points = Progression.unspent(unit)
	_title.text = "LEVEL UP  —  %s  (Level %d)" % [unit.get_display_name(), Progression.level]
	_name_edit.text = unit.get_display_name()
	_preview_texture.texture = unit.portrait_texture
	_portrait_placeholder.visible = unit.portrait_texture == null

	for id in _attribute_ids:
		var value: int = unit.get_base_stat(StringName(id))
		_attribute_values[id] = value
		_floor_attributes[id] = value

	var known: Dictionary = _known_skills(unit)
	for skill in SkillDatabase.get_all():
		var instance: SkillInstance = known.get(skill.skill_name)
		var value: int = instance.levels_purchased - 1 if instance != null else SKILL_TABLE.default_value
		_skill_values[skill.skill_name] = value
		_floor_skills[skill.skill_name] = value

	for child in _abilities_list.get_children():
		_abilities_list.remove_child(child)
		child.queue_free()
	_ability_boxes.clear()
	var learnable: Array[Ability] = []
	for ability in AbilityDatabase.get_all():
		if Progression.TABLE.is_learnable(ability) and not _knows_ability(unit, ability):
			learnable.append(ability)
	learnable.sort_custom(func(a: Ability, b: Ability) -> bool: return a.ability_name < b.ability_name)
	for ability in learnable:
		var box := CheckBox.new()
		box.text = ability.ability_name
		box.icon = ability.icon
		box.expand_icon = false
		box.toggled.connect(_on_ability_toggled.bind(ability))
		_abilities_list.add_child(box)
		_ability_boxes[ability] = box

	_tabs.current_tab = TAB_ATTRIBUTES


## skill name -> SkillInstance.
func _known_skills(unit: Unit) -> Dictionary:
	var known: Dictionary = {}
	for instance in unit.get_skills():
		if instance.skill_data != null:
			known[instance.skill_data.skill_name] = instance
	return known


func _knows_ability(unit: Unit, ability: Ability) -> bool:
	for owned in unit.abilities:
		if owned != null and owned.ability_name == ability.ability_name:
			return true
	return false


## Level-up mode on `unit`. Returns why it could not open, or "" when it
## did. The state is set BEFORE open(): opening is what runs reset().
func open_level_up(unit: Unit) -> String:
	if not is_instance_valid(unit):
		return "No one to level up."
	if unit.encounter != null and unit.encounter.is_running:
		return "Not during a fight."
	if not Progression.has_unspent(unit):
		return "%s has no points to spend." % unit.get_display_name()
	if visible or not UIStack.can_open():
		return "Close the open screen first."
	_level_up_unit = unit
	open()
	return ""


func is_levelling_up() -> bool:
	return _level_up_unit != null


func _on_visibility_changed() -> void:
	if visible:
		reset()
	else:
		# Whatever closed it, the next open is a new character unless
		# open_level_up says otherwise.
		_level_up_unit = null


func _on_new_game_started() -> void:
	_level_up_unit = null
	reset()


func _exit_tree() -> void:
	if SaveManager.has_signal("new_game_started") and SaveManager.new_game_started.is_connected(_on_new_game_started):
		SaveManager.new_game_started.disconnect(_on_new_game_started)


## One row per attribute/skill, instanced from point_buy_row.tscn so its
## look is edited in the editor, not here. Only the per-row text and the
## +/- wiring are set from code.
func _build_row(parent: VBoxContainer, label_text: String, tag_text: String, tooltip: String, key: String, row_registry: Dictionary, step_callback: Callable) -> void:
	var row: HBoxContainer = POINT_BUY_ROW.instantiate()
	parent.add_child(row)

	var name_label: Label = row.get_node("NameLabel")
	name_label.text = label_text
	name_label.tooltip_text = tooltip
	var tag_label: Label = row.get_node("TagLabel")
	tag_label.text = tag_text

	var minus: Button = row.get_node("Minus")
	minus.pressed.connect(step_callback.bind(key, -1))
	var plus: Button = row.get_node("Plus")
	plus.pressed.connect(step_callback.bind(key, 1))

	row_registry[key] = {"minus": minus, "plus": plus, "value_label": row.get_node("ValueLabel"), "cost_label": row.get_node("CostLabel")}


func _on_attribute_step(attr: String, delta: int) -> void:
	if not _can_afford_step(ATTRIBUTE_TABLE, _attribute_values, _floor_attributes, ATTRIBUTE_POOL, attr, delta):
		return
	_attribute_values[attr] = _attribute_values[attr] + delta
	_refresh_attributes()


func _on_skill_step(skill_name: String, delta: int) -> void:
	if not _can_afford_step(SKILL_TABLE, _skill_values, _floor_skills, SKILL_POOL, skill_name, delta):
		return
	_skill_values[skill_name] = _skill_values[skill_name] + delta
	_refresh_skills()


## The actual enforcement of "points remaining can never go negative" —
## lives here, not just in the button-disabled state _refresh_* also
## sets. That disabled state exists for real-time UI feedback (so a
## player sees a "+" go dim before ever pressing it), but it's a
## REFLECTION of this rule, not the only thing enforcing it — this
## function has to independently refuse an unaffordable step regardless
## of whether it was reached through a live (non-disabled) button or any
## other future caller.
func _can_afford_step(table: PointBuyTable, values: Dictionary, floors: Dictionary, pool: StringName, key: String, delta: int) -> bool:
	var new_value: int = values[key] + delta
	if new_value < _lowest(table, floors, key) or new_value > _highest(table, floors, key):
		return false
	if delta > 0:
		var marginal_cost: int = _step_cost(table, values[key], new_value)
		if marginal_cost > _remaining(table, values, floors, pool):
			return false
	return true


## Which of Progression's pools a table spends from in level-up mode.
const ATTRIBUTE_POOL := &"attributes"
const SKILL_POOL := &"skills"


## A row's bounds. Creating: the table's. Levelling: from the member's
## current value (no selling back) up to the table's cap — or no higher
## than they already are, for a member authored past it, since the
## table has no price for those values.
func _lowest(table: PointBuyTable, floors: Dictionary, key: String) -> int:
	return floors.get(key, table.min_value)


func _highest(table: PointBuyTable, floors: Dictionary, key: String) -> int:
	return maxi(table.max_value, floors.get(key, table.min_value))


## Points left. Creating: the table's own pool less the whole build.
## Levelling: what the member has unspent less what this visit raised —
## the cost of each row now over its cost at the floor.
func _remaining(table: PointBuyTable, values: Dictionary, floors: Dictionary, pool: StringName) -> int:
	if _level_up_unit == null:
		return table.points_remaining(values)
	return int(_points.get(pool, 0)) - _spent(table, values, floors)


func _spent(table: PointBuyTable, values: Dictionary, floors: Dictionary) -> int:
	var spent: int = 0
	for key in values:
		spent += _step_cost(table, floors.get(key, values[key]), values[key])
	return spent


## What raising a row from one value to another costs. Creating: the
## table's price difference. Levelling: plain points, 1 per +1.
func _step_cost(table: PointBuyTable, from: int, to: int) -> int:
	if _level_up_unit != null:
		return to - from
	return table.cost_for(to) - table.cost_for(from)


## A row's price column. Creating: what the value costs from the
## table. Levelling: how much this visit has raised it, if anything.
func _cost_text(table: PointBuyTable, floors: Dictionary, key: String, value: int) -> String:
	if _level_up_unit == null:
		return "cost %d" % table.cost_for(value)
	var raised: int = value - int(floors.get(key, value))
	return "+%d" % raised if raised > 0 else ""


func _picks_left() -> int:
	return int(_points.get(&"abilities", 0)) - _picked_abilities.size()


## Refuses a "+" the instant the NEXT step's marginal cost would exceed
## what's left to spend — points_remaining must never go negative and
## then need clawing back, it should simply not be reachable through the
## UI at all. "-" needs no equivalent guard: lowering a value only ever
## refunds or holds cost steady on both of these tables, it can never
## itself cause an overspend.
func _refresh_attributes() -> void:
	var remaining: int = _remaining(ATTRIBUTE_TABLE, _attribute_values, _floor_attributes, ATTRIBUTE_POOL)
	for id in _attribute_ids:
		var value: int = _attribute_values[id]
		var row: Dictionary = _attribute_rows[id]
		row["value_label"].text = str(value)
		row["cost_label"].text = _cost_text(ATTRIBUTE_TABLE, _floor_attributes, id, value)
		row["minus"].disabled = value <= _lowest(ATTRIBUTE_TABLE, _floor_attributes, id)
		var next_step_cost: int = _step_cost(ATTRIBUTE_TABLE, value, value + 1)
		row["plus"].disabled = value >= _highest(ATTRIBUTE_TABLE, _floor_attributes, id) or next_step_cost > remaining

	_attributes_header.text = "ATTRIBUTES  —  Points remaining: %d" % remaining
	var parts: PackedStringArray = []
	for id in _attribute_ids:
		parts.append("%s %d" % [StatDatabase.find(StringName(id)).label(), _attribute_values[id]])
	_attribute_summary.text = "   ".join(parts)
	var derived: PackedStringArray = []
	for definition in StatDatabase.get_all():
		if definition.is_derived():
			derived.append("%s %s" % [definition.label(), StatDefinition.format(_preview_value(definition.id))])
	_derived_summary.text = "   ".join(derived)
	_update_confirm_state()


## A stat's value for the build so far — the bought values, every other
## stat at its default, nothing applied. What the unit will spawn with.
func _preview_value(id: StringName) -> float:
	var base_of := func(stat_id: StringName) -> int:
		var definition := StatDatabase.find(stat_id)
		return _attribute_values.get(String(stat_id), definition.default_value if definition else 0)
	return StatDatabase.value_of(id, base_of, func(_id: StringName) -> int: return 0)


func _refresh_skills() -> void:
	var remaining: int = _remaining(SKILL_TABLE, _skill_values, _floor_skills, SKILL_POOL)
	for skill_name in _skill_values:
		var value: int = _skill_values[skill_name]
		var row: Dictionary = _skill_rows[skill_name]
		row["value_label"].text = "%+d" % value
		row["cost_label"].text = _cost_text(SKILL_TABLE, _floor_skills, skill_name, value)
		row["minus"].disabled = value <= _lowest(SKILL_TABLE, _floor_skills, skill_name)
		var next_step_cost: int = _step_cost(SKILL_TABLE, value, value + 1)
		row["plus"].disabled = value >= _highest(SKILL_TABLE, _floor_skills, skill_name) or next_step_cost > remaining

	_skills_header.text = "SKILLS  —  Points remaining: %d" % remaining
	_update_confirm_state()


## A box can be ticked while picks remain; once they are used up only
## the ticked ones stay live, so a pick can always be taken back.
func _refresh_abilities() -> void:
	var left: int = _picks_left()
	for ability in _ability_boxes:
		var box: CheckBox = _ability_boxes[ability]
		box.set_pressed_no_signal(ability in _picked_abilities)
		box.disabled = left <= 0 and not box.button_pressed
	_abilities_header.text = "ABILITIES  —  Picks remaining: %d" % left
	if _level_up_unit != null and _ability_boxes.is_empty():
		_abilities_header.text += "  (nothing left to learn)"
	_update_confirm_state()


func _on_ability_toggled(on: bool, ability: Ability) -> void:
	if on and not ability in _picked_abilities and _picks_left() > 0:
		_picked_abilities.append(ability)
	elif not on:
		_picked_abilities.erase(ability)
	_refresh_abilities()


## Scans PORTRAITS_DIR directly rather than any authored list — "they're
## all resources already" was the whole point (per the user's own
## framing): a new file dropped in that folder shows up here with no
## code change, same "theoretically infinite by scanning a folder"
## convention SkillDatabase/DemonDatabase already use.
func _build_portrait_grid() -> void:
	for file_name in DirAccess.get_files_at(PORTRAITS_DIR):
		var extension: String = file_name.get_extension().to_lower()
		if extension not in PORTRAIT_EXTENSIONS:
			continue

		var path: String = PORTRAITS_DIR + file_name
		var texture: Texture2D = load(path)
		if not texture:
			continue

		var button := Button.new()
		button.flat = true
		button.custom_minimum_size = PORTRAIT_ASPECT_RATIO * PORTRAIT_GRID_CELL_SCALE
		button.toggle_mode = true
		button.pressed.connect(_on_portrait_selected.bind(path))
		_portrait_grid.add_child(button)

		var thumb := TextureRect.new()
		thumb.texture = texture
		thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		thumb.set_anchors_preset(Control.PRESET_FULL_RECT)
		button.add_child(thumb)

		_portrait_buttons[path] = button


func _on_portrait_selected(path: String) -> void:
	if _selected_portrait_path == path:
		return
	if _selected_portrait_path in _portrait_buttons:
		_portrait_buttons[_selected_portrait_path].button_pressed = false
	_selected_portrait_path = path
	_portrait_buttons[path].button_pressed = true
	_preview_texture.texture = load(path)
	_portrait_placeholder.visible = false
	_update_confirm_state()


## Also writes the sheet's checklist, from the same four conditions, so
## a disabled BEGIN ADVENTURE always says what it is waiting for.
func _update_confirm_state() -> void:
	if _level_up_unit != null:
		_update_level_up_confirm_state()
		return
	var name_given: bool = not _name_edit.text.strip_edges().is_empty()
	var portrait_given: bool = not _selected_portrait_path.is_empty()
	var attributes_done: bool = ATTRIBUTE_TABLE.is_valid(_attribute_values)
	var skills_done: bool = SKILL_TABLE.is_valid(_skill_values)
	_confirm_button.disabled = not (name_given and portrait_given and attributes_done and skills_done)

	var lines: PackedStringArray = []
	lines.append(_checklist_line(name_given, "Name"))
	lines.append(_checklist_line(portrait_given, "Portrait"))
	lines.append(_checklist_line(attributes_done, "Attributes (%d points left)" % ATTRIBUTE_TABLE.points_remaining(_attribute_values)))
	lines.append(_checklist_line(skills_done, "Skills (%d points left)" % SKILL_TABLE.points_remaining(_skill_values)))
	_checklist.text = "\n".join(lines)


## Levelling has nothing it MUST spend — points carry over — so LEVEL UP
## is live as soon as anything changed.
func _update_level_up_confirm_state() -> void:
	var attributes_spent: int = _spent(ATTRIBUTE_TABLE, _attribute_values, _floor_attributes)
	var skills_spent: int = _spent(SKILL_TABLE, _skill_values, _floor_skills)
	_confirm_button.disabled = attributes_spent == 0 and skills_spent == 0 and _picked_abilities.is_empty()
	var lines: PackedStringArray = []
	lines.append("Attributes: %d points left" % _remaining(ATTRIBUTE_TABLE, _attribute_values, _floor_attributes, ATTRIBUTE_POOL))
	lines.append("Skills: %d points left" % _remaining(SKILL_TABLE, _skill_values, _floor_skills, SKILL_POOL))
	lines.append("Abilities: %d picks left" % _picks_left())
	lines.append("Unspent points carry over.")
	_checklist.text = "\n".join(lines)


func _checklist_line(done: bool, text: String) -> String:
	return ("[x]  " if done else "[  ]  ") + text


func _on_name_text_changed(_new_text: String) -> void:
	_update_confirm_state()


func _on_confirm_pressed() -> void:
	if _confirm_button.disabled:
		return
	if _level_up_unit != null:
		_confirm_level_up()
		return

	var record := PartyMemberData.new()
	# A body, like every other unit in the game has. Every stat below is
	# applied over the top of this definition's cascade by
	# PartyManager.spawn_member, so what it actually supplies is the model —
	# which is the whole reason a chargen character had no visuals at all.
	#
	# One body today. When there is more than one to pick from, this is the
	# line chargen chooses between, which is how Solasta does it: the race
	# you select supplies the body. Mass Effect adds a head morph on top of
	# a fixed base; BG3 goes furthest and assembles the visual from separate
	# race/head/hair parts. All three keep the definition — none of them
	# lets a character exist without one.
	record.definition = load("res://data/units/companions/player_character.tres")
	record.is_leader = true
	record.display_name = _name_edit.text.strip_edges()
	record.portrait_texture = load(_selected_portrait_path)
	record.faction = Unit.PLAYER_FACTION
	# A new character starts whole: every pool at the maximum this build
	# gives it, not the species' — an ST 14 character is not born at 10 HP.
	var pools: Dictionary = {}
	for definition in StatDatabase.get_all():
		if definition.is_pool:
			pools[String(definition.id)] = floori(_preview_value(definition.id))
	record.stats = {"stats": _attribute_values.duplicate(), "pools": pools}
	# Matches the other 3 hand-placed party members' own shared color,
	# authored directly on each of them in test_arena.tscn — visual party
	# consistency, not a Unit-script default. Belongs on the record itself
	# (not patched on after spawning, as this used to be) so it survives
	# every subsequent world reload the same way every other field does —
	# see PartyManager.spawn_member(), which now restores it unconditionally.
	record.selected_color = Color(0.156863, 1, 1, 0.627451)
	# Only the 3 abilities named as "standard for every unit" — a freshly
	# created blank character hasn't earned a spellbook by design; richer
	# abilities come from a future debug menu, not chargen.
	record.abilities = [
		load("res://data/abilities/basic_attack_melee.tres"),
		load("res://data/abilities/jump.tres"),
		load("res://data/abilities/shove.tres"),
	]

	for skill_name in _skill_values:
		var relative_level: int = _skill_values[skill_name]
		if relative_level == 0:
			continue  # no investment -- matches how an untrained skill just
			# defaults off the controlling attribute
		var skill: Skill = SkillDatabase.find(skill_name)
		if not skill:
			continue
		var skill_record := PartySkillRecord.new()
		skill_record.skill = skill
		# SkillInstance's own baseline is levels_purchased=1 ("just the base
		# attribute+difficulty roll"); Bucket C's own notation calls that
		# same baseline "+0" — the +1 reconciles those two conventions.
		skill_record.levels_purchased = relative_level + 1
		record.skills.append(skill_record)

	PartyManager.pending_leader = record

	# The one place the front end actually loads a world — this is the
	# moment the game proper begins. Nothing here touches GameMode: once a
	# world is focused, the mode reads that world's own get_base_mode().
	# Not close(): travel_area() closes this screen behind the fade.
	WorldManager.travel_area(&"goblin_quarry")


## Writes the visit onto the live Unit — PartyManager captures it from
## there like any other change — and hands Progression what was spent.
## Raising a pool's maximum raises its current value by the same amount
## (more ST is more HP now, not after a rest); nothing is ever lowered.
func _confirm_level_up() -> void:
	var unit: Unit = _level_up_unit
	if not is_instance_valid(unit):
		close()
		return
	var attributes_spent: int = _spent(ATTRIBUTE_TABLE, _attribute_values, _floor_attributes)
	var skills_spent: int = _spent(SKILL_TABLE, _skill_values, _floor_skills)
	if not Progression.spend(unit, attributes_spent, skills_spent, _picked_abilities.size()):
		push_warning("Level up: spent more than %s had." % unit.get_display_name())
		return

	var pool_maxes: Dictionary = {}
	for definition in StatDatabase.get_all():
		if definition.is_pool:
			pool_maxes[definition.id] = floori(unit.get_stat(definition.id))
	for id in _attribute_ids:
		if _attribute_values[id] != _floor_attributes[id]:
			unit.set_base_stat(StringName(id), _attribute_values[id])
	for pool_id in pool_maxes:
		var gained: int = floori(unit.get_stat(pool_id)) - pool_maxes[pool_id]
		if gained > 0:
			unit.set_pool(pool_id, unit.get_pool(pool_id) + gained)

	var known: Dictionary = _known_skills(unit)
	for skill_name in _skill_values:
		var value: int = _skill_values[skill_name]
		if value == _floor_skills[skill_name]:
			continue
		if known.has(skill_name):
			(known[skill_name] as SkillInstance).levels_purchased = value + 1
			continue
		var skill: Skill = SkillDatabase.find(skill_name)
		if skill == null:
			continue
		var instance := SkillInstance.new()
		instance.skill_data = skill
		instance.levels_purchased = value + 1  # see _on_confirm_pressed's +1
		add_child(instance)  # add_skill reparents, so it needs a parent first
		unit.add_skill(instance)

	for ability in _picked_abilities:
		unit.add_ability(ability)

	SystemLog.print("[b]%s levelled up.[/b]" % unit.get_display_name())
	close()


## Debug: a valid build in every field, through the same step and
## selection functions the buttons use, so it can never produce a
## character the UI itself could not. Starts from reset() so it is
## deterministic regardless of what was typed before.
func _on_auto_fill_pressed() -> void:
	_level_up_unit = null
	reset()
	_name_edit.text = QUICK_CREATE_NAME
	if not _portrait_buttons.is_empty():
		_on_portrait_selected(_portrait_buttons.keys()[0])

	var attributes: Array[String] = []
	attributes.assign(_attribute_ids)
	_spend_round_robin(attributes, _on_attribute_step, ATTRIBUTE_TABLE, _attribute_values, _floor_attributes, ATTRIBUTE_POOL)

	var skills: Array[String] = []
	for skill_name in QUICK_CREATE_SKILLS:
		if skill_name in _skill_values:
			skills.append(skill_name)
	if skills.is_empty():
		skills.assign(_skill_values.keys())
	_spend_round_robin(skills, _on_skill_step, SKILL_TABLE, _skill_values, _floor_skills, SKILL_POOL)

	_update_confirm_state()


## +1 to each key in turn until the pool is empty or nothing more is
## affordable. Spreads points evenly instead of maxing one stat.
func _spend_round_robin(keys: Array[String], step: Callable, table: PointBuyTable, values: Dictionary, floors: Dictionary, pool: StringName) -> void:
	var progressed: bool = true
	while progressed and table.points_remaining(values) > 0:
		progressed = false
		for key in keys:
			if table.points_remaining(values) <= 0:
				break
			if _can_afford_step(table, values, floors, pool, key, 1):
				step.call(key, 1)
				progressed = true


## Debug: auto-fill, then straight into the game.
func _on_quick_create_pressed() -> void:
	_on_auto_fill_pressed()
	if _confirm_button.disabled:
		push_warning("Quick create: auto-fill did not produce a valid build — %s" % _checklist.text.replace("\n", "; "))
		return
	_on_confirm_pressed()


func _on_back_pressed() -> void:
	if _level_up_unit != null:
		close()  # cancel: nothing was written
		return
	# close() first: with no world loaded the mode is read off which front
	# end screen is open, so closing this one is what makes it MAIN_MENU.
	close()
	UIStack.push(get_tree().get_first_node_in_group("main_menu"))
