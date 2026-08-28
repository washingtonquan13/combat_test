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
## State deliberately survives backing out to the title screen and
## returning (this screen is instanced once, not rebuilt per visit) — a
## player who steps back shouldn't lose an in-progress build.

const ATTRIBUTE_TABLE: PointBuyTable = preload("res://data/character_creation/attribute_costs.tres")
const SKILL_TABLE: PointBuyTable = preload("res://data/character_creation/skill_costs.tres")
const TEST_ARENA_SCENE: PackedScene = preload("res://test_arena.tscn")

const ATTRIBUTE_NAMES: Array[String] = ["strength", "dexterity", "intelligence", "health"]
const ATTRIBUTE_LABELS: Dictionary = {
	"strength": "Strength",
	"dexterity": "Dexterity",
	"intelligence": "Intelligence",
	"health": "Health",
}

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

@onready var _name_edit: LineEdit = %NameEdit
@onready var _portrait_grid: GridContainer = %PortraitGrid
@onready var _preview_texture: TextureRect = %PreviewTexture
@onready var _attributes_header: Label = %AttributesHeader
@onready var _attributes_list: VBoxContainer = %AttributesList
@onready var _skills_header: Label = %SkillsHeader
@onready var _skills_list: VBoxContainer = %SkillsList
@onready var _confirm_button: Button = %ConfirmButton

var _attribute_values: Dictionary = {}  # String -> int
var _skill_values: Dictionary = {}  # String (skill name) -> int (relative level)
var _attribute_rows: Dictionary = {}  # String -> Dictionary (row's own widgets)
var _skill_rows: Dictionary = {}
var _portrait_buttons: Dictionary = {}  # String (res:// path) -> Button, for selection highlighting
var _selected_portrait_path: String = ""


func _enter_tree() -> void:
	# So main_menu.gd's Start can find this screen without holding a
	# NodePath to it — same find-by-role idiom party_overview/
	# conversation_log/esc_menu already use. In _enter_tree rather than
	# _ready so it's discoverable regardless of sibling _ready order.
	add_to_group("character_creation")


func _ready() -> void:
	for attr in ATTRIBUTE_NAMES:
		_attribute_values[attr] = ATTRIBUTE_TABLE.default_value
		_build_row(_attributes_list, ATTRIBUTE_LABELS[attr], attr, _attribute_rows, _on_attribute_step)

	for skill in SkillDatabase.get_all():
		_skill_values[skill.skill_name] = SKILL_TABLE.default_value
		_build_row(_skills_list, skill.skill_name, skill.skill_name, _skill_rows, _on_skill_step)

	_build_portrait_grid()

	_refresh_attributes()
	_refresh_skills()
	_update_confirm_state()


func _build_row(parent: VBoxContainer, label_text: String, key: String, row_registry: Dictionary, step_callback: Callable) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)

	var name_label := Label.new()
	name_label.text = label_text
	name_label.custom_minimum_size = Vector2(120, 0)
	row.add_child(name_label)

	var minus := Button.new()
	minus.text = "-"
	minus.custom_minimum_size = Vector2(28, 0)
	minus.pressed.connect(step_callback.bind(key, -1))
	row.add_child(minus)

	var value_label := Label.new()
	value_label.custom_minimum_size = Vector2(40, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(value_label)

	var plus := Button.new()
	plus.text = "+"
	plus.custom_minimum_size = Vector2(28, 0)
	plus.pressed.connect(step_callback.bind(key, 1))
	row.add_child(plus)

	var cost_label := Label.new()
	cost_label.custom_minimum_size = Vector2(70, 0)
	row.add_child(cost_label)

	row_registry[key] = {"minus": minus, "plus": plus, "value_label": value_label, "cost_label": cost_label}


func _on_attribute_step(attr: String, delta: int) -> void:
	if not _can_afford_step(ATTRIBUTE_TABLE, _attribute_values, attr, delta):
		return
	_attribute_values[attr] = _attribute_values[attr] + delta
	_refresh_attributes()


func _on_skill_step(skill_name: String, delta: int) -> void:
	if not _can_afford_step(SKILL_TABLE, _skill_values, skill_name, delta):
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
func _can_afford_step(table: PointBuyTable, values: Dictionary, key: String, delta: int) -> bool:
	var new_value: int = values[key] + delta
	if new_value < table.min_value or new_value > table.max_value:
		return false
	if delta > 0:
		var marginal_cost: int = table.cost_for(new_value) - table.cost_for(values[key])
		if marginal_cost > table.points_remaining(values):
			return false
	return true


## Refuses a "+" the instant the NEXT step's marginal cost would exceed
## what's left to spend — points_remaining must never go negative and
## then need clawing back, it should simply not be reachable through the
## UI at all. "-" needs no equivalent guard: lowering a value only ever
## refunds or holds cost steady on both of these tables, it can never
## itself cause an overspend.
func _refresh_attributes() -> void:
	var remaining: int = ATTRIBUTE_TABLE.points_remaining(_attribute_values)
	for attr in ATTRIBUTE_NAMES:
		var value: int = _attribute_values[attr]
		var row: Dictionary = _attribute_rows[attr]
		row["value_label"].text = str(value)
		row["cost_label"].text = "cost %d" % ATTRIBUTE_TABLE.cost_for(value)
		row["minus"].disabled = value <= ATTRIBUTE_TABLE.min_value
		var next_step_cost: int = ATTRIBUTE_TABLE.cost_for(value + 1) - ATTRIBUTE_TABLE.cost_for(value)
		row["plus"].disabled = value >= ATTRIBUTE_TABLE.max_value or next_step_cost > remaining

	_attributes_header.text = "ATTRIBUTES  —  Points remaining: %d" % remaining
	_update_confirm_state()


func _refresh_skills() -> void:
	var remaining: int = SKILL_TABLE.points_remaining(_skill_values)
	for skill_name in _skill_values:
		var value: int = _skill_values[skill_name]
		var row: Dictionary = _skill_rows[skill_name]
		row["value_label"].text = "%+d" % value
		row["cost_label"].text = "cost %d" % SKILL_TABLE.cost_for(value)
		row["minus"].disabled = value <= SKILL_TABLE.min_value
		var next_step_cost: int = SKILL_TABLE.cost_for(value + 1) - SKILL_TABLE.cost_for(value)
		row["plus"].disabled = value >= SKILL_TABLE.max_value or next_step_cost > remaining

	_skills_header.text = "SKILLS  —  Points remaining: %d" % remaining
	_update_confirm_state()


## Scans PORTRAITS_DIR directly rather than any authored list — "they're
## all resources already" was the whole point (per the user's own
## framing): a new file dropped in that folder shows up here with no
## code change, same "theoretically infinite by scanning a folder"
## convention SkillDatabase/DemonDatabase/MusicTrackDatabase already use.
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
	_update_confirm_state()


func _update_confirm_state() -> void:
	var name_given: bool = not _name_edit.text.strip_edges().is_empty()
	var portrait_given: bool = not _selected_portrait_path.is_empty()
	_confirm_button.disabled = not (name_given and portrait_given and ATTRIBUTE_TABLE.is_valid(_attribute_values) and SKILL_TABLE.is_valid(_skill_values))


func _on_name_text_changed(_new_text: String) -> void:
	_update_confirm_state()


func _on_confirm_pressed() -> void:
	if _confirm_button.disabled:
		return

	var record := PartyMemberData.new()
	record.is_leader = true
	record.display_name = _name_edit.text.strip_edges()
	record.portrait_texture = load(_selected_portrait_path)
	record.faction = Unit.PLAYER_FACTION
	record.strength = _attribute_values["strength"]
	record.dexterity = _attribute_values["dexterity"]
	record.intelligence = _attribute_values["intelligence"]
	record.health = _attribute_values["health"]
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
	# moment the game proper begins. load_world() sets the base mode
	# itself off test_arena.gd's own get_base_mode(), so nothing here
	# needs to touch GameMode.
	close()
	WorldManager.load_world(TEST_ARENA_SCENE)


func _on_back_pressed() -> void:
	GameMode.set_base_mode(GameMode.Mode.MAIN_MENU)
	close()
	UIStack.push(get_tree().get_first_node_in_group("main_menu"))
