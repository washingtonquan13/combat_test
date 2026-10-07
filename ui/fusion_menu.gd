class_name FusionMenu
extends UIScreen
## The Cathedral's fusion menu, modelled on Nocturne's: pick one demon,
## pick a second from a list that already shows what each pairing would
## make, look at the result, then answer one "are you sure?".
##
## TWO STEPS, ONE LIST. The first step lists the roster. The second lists
## it again without the first pick, with three extra columns for the
## result, and a pairing that makes nothing is greyed out and cannot be
## chosen. The player never picks a pair and is then told "no"; the list
## says so before they choose.
##
## The three tabs (Demon 1, Demon 2, Result) are DemonSheets, filled from
## whichever row is HIGHLIGHTED rather than chosen, so moving down the list
## is how you compare.
##
## Cancel goes back one step at a time: from the second list to the first
## (with your first pick still highlighted), and from the first list out.
## UIStack's own cancel is turned off (closes_on_cancel) because it can only
## close the whole screen.
##
## THIS SCREEN DOES NOT FUSE. It says which two were chosen
## (fusion_confirmed) and closes. The Cathedral owns what happens next: the
## ritual and the cutscene, then its own menu back.

## The Minister's line changed. The Cathedral shows it in its speech box.
signal says(line: String)
## The player said yes. The screen has already closed itself.
signal fusion_confirmed(first: OwnedDemon, second: OwnedDemon)

enum Step { FIRST, SECOND }

## What the Minister says at each step. The words are data, so they can be
## changed in the inspector.
@export var first_prompt: String = "Which demon will you offer?"
@export var second_prompt: String = "And which shall be joined with it?"
@export var cancelled_line: String = "As you wish."
@export var too_few_line: String = "Fusion needs two demons. Return when you have them."
## %s is filled with the two demons and the result, in that order.
@export_multiline var confirm_text: String = "Fuse %s and %s into %s?\nAre you sure?"
## A row that cannot be chosen is drawn in this colour.
@export var unavailable_color: Color = Color(1.0, 1.0, 1.0, 0.35)

const FIRST_COLUMNS: PackedStringArray = ["Race", "Name", "Rank"]
const SECOND_COLUMNS: PackedStringArray = ["Race", "Name", "Rank", "Result", "Name", "Rank"]
## Relative widths of Race, Name and Rank; the result columns repeat them.
const COLUMN_RATIOS: PackedInt32Array = [2, 3, 1]
const DEMON_1_TAB: int = 0
const DEMON_2_TAB: int = 1
const RESULT_TAB: int = 2

@onready var _step_label: Label = %StepLabel
@onready var _list: Tree = %DemonList
@onready var _tabs: TabContainer = %Tabs
@onready var _demon_1: DemonSheet = %Demon1Sheet
@onready var _demon_2: DemonSheet = %Demon2Sheet
@onready var _result: DemonSheet = %ResultSheet
@onready var _confirm: ConfirmationDialog = %Confirm

var _step: Step = Step.FIRST
var _first: OwnedDemon = null
var _second: OwnedDemon = null
## The demons in the list, in row order. A row's metadata is its index here.
var _rows: Array[OwnedDemon] = []


func _ready() -> void:
	_list.item_selected.connect(_on_highlighted)
	_list.item_activated.connect(_on_chosen)
	_confirm.confirmed.connect(_on_yes)
	_confirm.canceled.connect(func() -> void: _list.grab_focus())


## Opens on the first step. Does not open, and says why, when the roster
## cannot make a pair.
func begin() -> bool:
	if _choosable(DemonRoster.all_owned()).size() < 2:
		says.emit(too_few_line)
		return false
	_first = null
	_second = null
	open()
	_show_first()
	return true


## Which step is showing.
func step() -> Step:
	return _step


## Cancel: second list back to the first, first list out. Handled here
## rather than by UIStack, which can only close the whole screen.
func back() -> void:
	if _step == Step.SECOND:
		_show_first()
		return
	close()
	says.emit(cancelled_line)


func _unhandled_input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not event.is_action_pressed("ui_cancel"):
		return
	get_viewport().set_input_as_handled()
	back()


func _show_first() -> void:
	_step = Step.FIRST
	_step_label.text = "First demon"
	_fill(DemonRoster.all_owned(), FIRST_COLUMNS)
	_demon_2.show_demon(null)
	_result.show_demon(null)
	_tabs.current_tab = DEMON_1_TAB
	_highlight(_first)
	says.emit(first_prompt)


func _show_second() -> void:
	_step = Step.SECOND
	_step_label.text = "Second demon, with %s" % _first.species.display_name
	var others: Array[OwnedDemon] = DemonRoster.all_owned()
	others.erase(_first)
	_fill(others, SECOND_COLUMNS)
	_demon_1.show_demon(_first.species, _first)
	_tabs.current_tab = RESULT_TAB
	_highlight(null)
	says.emit(second_prompt)


## Rebuilds the list for one step. A row is greyed and cannot be chosen
## when the demon is out in the world, or (second step) makes nothing with
## the first pick. The reason is the row's tooltip.
func _fill(entries: Array[OwnedDemon], titles: PackedStringArray) -> void:
	_list.clear()
	_list.columns = titles.size()
	for column in titles.size():
		_list.set_column_title(column, titles[column])
		_list.set_column_expand(column, true)
		_list.set_column_expand_ratio(column, COLUMN_RATIOS[column % COLUMN_RATIOS.size()])
	var root: TreeItem = _list.create_item()
	_rows = entries
	for index in entries.size():
		var owned: OwnedDemon = entries[index]
		var row: TreeItem = _list.create_item(root)
		row.set_metadata(0, index)
		var cells: Array = _cells(owned.species)
		var why_not: String = _why_not(owned)
		if titles.size() > FIRST_COLUMNS.size():
			var result: UnitDefinition = FusionRitual.preview(_first, owned)
			cells.append_array(_cells(result) if result else ["-", "-", "-"])
			if result == null and why_not == "":
				why_not = "These two make nothing."
		for column in cells.size():
			row.set_text(column, str(cells[column]))
			row.set_selectable(column, why_not == "")
			row.set_tooltip_text(column, why_not)
			if why_not != "":
				row.set_custom_color(column, unavailable_color)


func _cells(species: UnitDefinition) -> Array:
	return [String(species.order), species.display_name, species.rank]


## Why a demon cannot be chosen right now, or "" if it can.
func _why_not(owned: OwnedDemon) -> String:
	if DemonRoster.is_fielded(owned):
		return "Out in the world. Dismiss it first."
	return ""


func _choosable(entries: Array[OwnedDemon]) -> Array[OwnedDemon]:
	return entries.filter(func(owned: OwnedDemon) -> bool: return _why_not(owned) == "")


## Highlights `wanted`'s row, or else the first row that can be chosen.
func _highlight(wanted: OwnedDemon) -> void:
	var pick: TreeItem = null
	for row in _list.get_root().get_children():
		if not row.is_selectable(0):
			continue
		if pick == null or _rows[row.get_metadata(0)] == wanted:
			pick = row
	if pick:
		pick.select(0)
		_list.scroll_to_item(pick)
	_on_highlighted()
	_list.grab_focus.call_deferred()


func _highlighted() -> OwnedDemon:
	var row: TreeItem = _list.get_selected()
	return _rows[row.get_metadata(0)] if row else null


func _on_highlighted() -> void:
	var owned: OwnedDemon = _highlighted()
	if _step == Step.FIRST:
		_demon_1.show_demon(owned.species if owned else null, owned)
		return
	_demon_2.show_demon(owned.species if owned else null, owned)
	_result.show_demon(FusionRitual.preview(_first, owned) if owned else null)


func _on_chosen() -> void:
	var owned: OwnedDemon = _highlighted()
	if owned == null:
		return
	if _step == Step.FIRST:
		_first = owned
		_show_second()
		return
	var result: UnitDefinition = FusionRitual.preview(_first, owned)
	if result == null:
		return
	_second = owned
	_confirm.dialog_text = confirm_text % [
		_first.species.display_name, owned.species.display_name, result.display_name]
	_confirm.popup_centered()
	# No is the default, as in the reference: Enter pressed twice in a row
	# should not spend two demons.
	_confirm.get_cancel_button().grab_focus.call_deferred()


func _on_yes() -> void:
	var first: OwnedDemon = _first
	var second: OwnedDemon = _second
	close()
	fusion_confirmed.emit(first, second)
