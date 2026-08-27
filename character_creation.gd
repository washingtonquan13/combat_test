extends Control
## Character creation — building the player's own character (the future
## party leader, "THE MAIN CHARACTER" per the roadmap this was scoped
## against), via the point-buy tables verified for Buckets A (attributes)
## and C (skills). Bucket B is deliberately not part of this — see
## PointBuyTable's own header for why.
##
## Its own scene, reached only from main_menu.tscn's Start button, plain
## change_scene_to_file in and out — never SceneManager. This happens
## exactly once, right after New Game, with no game state yet in
## existence worth preserving on the way back if Back is pressed (see
## main_menu.gd's own header for the fuller reasoning on why the menu
## boundary doesn't use SceneManager's suspend/resume model).
##
## On Confirm, a real Unit can't be built yet — there's no arena loaded
## to place it in — so the result is written into PendingCharacter
## instead, and test_arena.gd applies it once MainRoot actually loads.

const ATTRIBUTE_TABLE: PointBuyTable = preload("res://data/character_creation/attribute_costs.tres")
const SKILL_TABLE: PointBuyTable = preload("res://data/character_creation/skill_costs.tres")

const ATTRIBUTE_NAMES: Array[String] = ["strength", "dexterity", "intelligence", "health"]
const ATTRIBUTE_LABELS: Dictionary = {
	"strength": "Strength",
	"dexterity": "Dexterity",
	"intelligence": "Intelligence",
	"health": "Health",
}

@onready var _name_edit: LineEdit = %NameEdit
@onready var _attributes_header: Label = %AttributesHeader
@onready var _attributes_list: VBoxContainer = %AttributesList
@onready var _skills_header: Label = %SkillsHeader
@onready var _skills_list: VBoxContainer = %SkillsList
@onready var _confirm_button: Button = %ConfirmButton

var _attribute_values: Dictionary = {}  # String -> int
var _skill_values: Dictionary = {}  # String (skill name) -> int (relative level)
var _attribute_rows: Dictionary = {}  # String -> Dictionary (row's own widgets)
var _skill_rows: Dictionary = {}


func _ready() -> void:
	for attr in ATTRIBUTE_NAMES:
		_attribute_values[attr] = ATTRIBUTE_TABLE.default_value
		_build_row(_attributes_list, ATTRIBUTE_LABELS[attr], attr, _attribute_rows, _on_attribute_step)

	for skill in SkillDatabase.get_all():
		_skill_values[skill.skill_name] = SKILL_TABLE.default_value
		_build_row(_skills_list, skill.skill_name, skill.skill_name, _skill_rows, _on_skill_step)

	_refresh_attributes()
	_refresh_skills()


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
	var new_value: int = _attribute_values[attr] + delta
	if new_value < ATTRIBUTE_TABLE.min_value or new_value > ATTRIBUTE_TABLE.max_value:
		return
	_attribute_values[attr] = new_value
	_refresh_attributes()


func _on_skill_step(skill_name: String, delta: int) -> void:
	var new_value: int = _skill_values[skill_name] + delta
	if new_value < SKILL_TABLE.min_value or new_value > SKILL_TABLE.max_value:
		return
	_skill_values[skill_name] = new_value
	_refresh_skills()


func _refresh_attributes() -> void:
	for attr in ATTRIBUTE_NAMES:
		var value: int = _attribute_values[attr]
		var row: Dictionary = _attribute_rows[attr]
		row["value_label"].text = str(value)
		row["cost_label"].text = "cost %d" % ATTRIBUTE_TABLE.cost_for(value)
		row["minus"].disabled = value <= ATTRIBUTE_TABLE.min_value
		row["plus"].disabled = value >= ATTRIBUTE_TABLE.max_value

	var remaining: int = ATTRIBUTE_TABLE.points_remaining(_attribute_values)
	_attributes_header.text = "ATTRIBUTES  —  Points remaining: %d" % remaining
	_update_confirm_state()


func _refresh_skills() -> void:
	for skill_name in _skill_values:
		var value: int = _skill_values[skill_name]
		var row: Dictionary = _skill_rows[skill_name]
		row["value_label"].text = "%+d" % value
		row["cost_label"].text = "cost %d" % SKILL_TABLE.cost_for(value)
		row["minus"].disabled = value <= SKILL_TABLE.min_value
		row["plus"].disabled = value >= SKILL_TABLE.max_value

	var remaining: int = SKILL_TABLE.points_remaining(_skill_values)
	_skills_header.text = "SKILLS  —  Points remaining: %d" % remaining
	_update_confirm_state()


func _update_confirm_state() -> void:
	var name_given: bool = not _name_edit.text.strip_edges().is_empty()
	_confirm_button.disabled = not (name_given and ATTRIBUTE_TABLE.is_valid(_attribute_values) and SKILL_TABLE.is_valid(_skill_values))


func _on_name_text_changed(_new_text: String) -> void:
	_update_confirm_state()


func _on_confirm_pressed() -> void:
	if _confirm_button.disabled:
		return

	PendingCharacter.display_name = _name_edit.text.strip_edges()
	PendingCharacter.strength = _attribute_values["strength"]
	PendingCharacter.dexterity = _attribute_values["dexterity"]
	PendingCharacter.intelligence = _attribute_values["intelligence"]
	PendingCharacter.health = _attribute_values["health"]
	PendingCharacter.skill_levels = _skill_values.duplicate()
	PendingCharacter.is_ready = true

	get_tree().change_scene_to_file("res://MainRoot.tscn")


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://main_menu.tscn")
