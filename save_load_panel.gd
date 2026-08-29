class_name SaveLoadPanel
extends UIScreen
## Single screen serving both SAVE and LOAD — one scrolling list of
## saves (see SaveManager.list_saves()), plus a name field and Save
## button that only show in SAVE mode. Same "one screen, mode flag"
## shape as InteractionMenu serving multiple verb contexts, rather than
## two near-identical screens.
##
## Rows are built at runtime, one per save — same dynamic-row idiom
## party_panel.gd already uses for its own per-member list, not authored
## per-row in the .tscn, since the row count is unbounded (unlimited
## timestamped saves, see SaveManager's own header).
##
## blocks_input_below=true is authored on this scene's instance in
## MainRoot.tscn — a save/load action mid-transfer with something else
## open underneath doesn't make sense. hides_hud/closes_on_cancel stay
## at UIScreen's own defaults (false, true).

enum Mode { SAVE, LOAD }

@onready var _title_label: Label = %TitleLabel
@onready var _save_row: HBoxContainer = %SaveRow
@onready var _name_edit: LineEdit = %NameEdit
@onready var _save_button: Button = %SaveButton
@onready var _row_list: VBoxContainer = %RowList
@onready var _empty_label: Label = %EmptyLabel

var _mode: Mode = Mode.LOAD


func _ready() -> void:
	visible = false
	%CloseButton.pressed.connect(func(): close())
	_save_button.pressed.connect(_on_save_pressed)
	_name_edit.text_submitted.connect(func(_text): _on_save_pressed())


## The one entry point callers use — main_menu.gd's LOAD GAME button and
## esc_menu.gd's SAVE/LOAD buttons all call this instead of open()
## directly, so the mode is always set before the screen becomes visible.
func open_for(mode: Mode) -> void:
	_mode = mode
	_title_label.text = "SAVE GAME" if mode == Mode.SAVE else "LOAD GAME"
	_save_row.visible = mode == Mode.SAVE
	if mode == Mode.SAVE:
		_name_edit.text = _default_save_name()
	_refresh_list()
	open()


func _default_save_name() -> String:
	var area: AreaDefinition = WorldManager.current_area()
	return area.display_name if area else "New Save"


func _refresh_list() -> void:
	for child in _row_list.get_children():
		child.queue_free()

	var saves: Array[Dictionary] = SaveManager.list_saves()
	_empty_label.visible = saves.is_empty()

	for entry in saves:
		_row_list.add_child(_build_row(entry))


func _build_row(entry: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var name_label := Label.new()
	name_label.text = entry.get("name", "")
	name_label.add_theme_font_size_override("font_size", 16)
	info.add_child(name_label)

	var detail_label := Label.new()
	detail_label.text = "%s · %s · %s" % [
		entry.get("area_display_name", ""),
		entry.get("leader_name", ""),
		_format_timestamp(entry.get("timestamp", 0)),
	]
	detail_label.add_theme_font_size_override("font_size", 12)
	detail_label.modulate.a = 0.7
	info.add_child(detail_label)

	row.add_child(info)

	var path: String = entry.get("path", "")

	var load_button := Button.new()
	load_button.text = "Load"
	load_button.pressed.connect(_on_load_pressed.bind(path))
	row.add_child(load_button)

	var delete_button := Button.new()
	delete_button.text = "Delete"
	delete_button.pressed.connect(_on_delete_pressed.bind(path))
	row.add_child(delete_button)

	return row


## ISO-ish UTC string — Godot's Time singleton has no clean way to
## convert an arbitrary stored Unix timestamp to the PLAYER's local time
## (only the current moment, via get_datetime_dict_from_system()), so
## this deliberately doesn't claim to be local time; UTC displayed
## honestly beats a wrong "local" label.
func _format_timestamp(timestamp: int) -> String:
	return Time.get_datetime_string_from_unix_time(timestamp, true)


func _on_save_pressed() -> void:
	var save_name: String = _name_edit.text.strip_edges()
	if save_name.is_empty():
		save_name = _default_save_name()
	if SaveManager.save(save_name):
		close()


func _on_load_pressed(path: String) -> void:
	if SaveManager.load_file(path):
		close()


func _on_delete_pressed(path: String) -> void:
	SaveManager.delete_save(path)
	_refresh_list()
