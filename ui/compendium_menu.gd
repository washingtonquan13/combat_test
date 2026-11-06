class_name CompendiumMenu
extends UIScreen
## The Cathedral's Demonic Compendium, modelled on Nocturne's: a book of
## every demon, where a page you have filled can be summoned back for gold,
## and a second list for recording the demons you own.
##
## TWO STEPS, ONE LIST, the same shape as FusionMenu.
##   BOOK      every species, by race then rank. A blank page is "?????"
##             and cannot be highlighted. Enter (or Summon) on a filled
##             page asks to summon it.
##   REGISTER  your demons. Enter (or Record) records that demon's page,
##             then returns to the book on it.
##
## A filled page you cannot afford CAN be highlighted, so you can read it;
## its cost is greyed and Summon is disabled, with the reason as tooltip.
##
## Cancel goes back one step at a time: from the register list to the
## book, and from the book out. UIStack's own cancel is turned off
## (closes_on_cancel) because it can only close the whole screen.
##
## The rules (what a page holds, what a summon costs) are DemonCompendium's.
## This screen only shows them and asks.

## The Minister's line changed. The Cathedral shows it in its speech box.
signal says(line: String)

enum Step { BOOK, REGISTER }

## What the Minister says. The words are data, so they can be changed in
## the inspector. %s is the demon's name.
@export var book_prompt: String = "Which demon will you call forth?"
@export var register_prompt: String = "Which demon shall be recorded?"
@export var recorded_line: String = "%s has been recorded."
@export var rerecorded_line: String = "%s's record has been rewritten."
@export var summoned_line: String = "%s answers the call."
@export var cannot_summon_line: String = "You cannot call that one. %s"
@export var no_demons_line: String = "You have no demons to record."
@export var cancelled_line: String = "As you wish."
## %s is the demon, %d the cost.
@export_multiline var confirm_text: String = "Summon %s for %d gold?\nAre you sure?"
## How a blank page's name is drawn.
@export var unknown_name: String = "?????"
## A row or cell that cannot be chosen is drawn in this colour.
@export var unavailable_color: Color = Color(1.0, 1.0, 1.0, 0.35)

const BOOK_COLUMNS: PackedStringArray = ["Race", "Name", "Rank", "Cost"]
const REGISTER_COLUMNS: PackedStringArray = ["Race", "Name", "Rank", "Recorded"]
const COLUMN_RATIOS: PackedInt32Array = [2, 3, 1, 1]
const COST_COLUMN: int = 3

@onready var _step_label: Label = %StepLabel
@onready var _gold_label: Label = %GoldLabel
@onready var _list: Tree = %DemonList
@onready var _summon_button: Button = %SummonButton
@onready var _register_button: Button = %RegisterButton
@onready var _record_button: Button = %RecordButton
@onready var _back_button: Button = %BackButton
@onready var _sheet: DemonSheet = %Sheet
@onready var _confirm: ConfirmationDialog = %Confirm

var _step: Step = Step.BOOK
## What each row is, in row order. A row's metadata is its index here:
## UnitDefinitions in the book, OwnedDemons in the register list.
var _rows: Array = []
## The species being asked about in the confirm dialog.
var _summoning: UnitDefinition = null


func _ready() -> void:
	_list.item_selected.connect(_on_highlighted)
	_list.item_activated.connect(_on_chosen)
	_summon_button.pressed.connect(_on_chosen)
	_register_button.pressed.connect(_show_register)
	_record_button.pressed.connect(_on_chosen)
	_back_button.pressed.connect(back)
	_confirm.confirmed.connect(_on_yes)
	_confirm.canceled.connect(func() -> void: _list.grab_focus())
	CurrencyManager.gold_changed.connect(func(_gold: int) -> void: _show_gold())


## Opens on the book.
func begin() -> void:
	open()
	_show_book()


## Which step is showing.
func step() -> Step:
	return _step


## Cancel: register list back to the book, book out.
func back() -> void:
	if _step == Step.REGISTER:
		_show_book()
		return
	close()
	says.emit(cancelled_line)


func _unhandled_input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not event.is_action_pressed("ui_cancel"):
		return
	get_viewport().set_input_as_handled()
	back()


## Every species, by race, then rank, then name. `focus` is highlighted if
## it has a page.
func _show_book(focus: UnitDefinition = null) -> void:
	_step = Step.BOOK
	_step_label.text = "Demonic Compendium"
	var species: Array[UnitDefinition] = DemonDatabase.get_all()
	species.sort_custom(_book_order)
	_start_list(BOOK_COLUMNS)
	_rows = species
	var root: TreeItem = _list.get_root()
	for index in species.size():
		var entry: UnitDefinition = species[index]
		var row: TreeItem = _list.create_item(root)
		row.set_metadata(0, index)
		var known: bool = DemonCompendium.is_registered(entry)
		var cells: Array = [String(entry.order), unknown_name, "-", "-"]
		if known:
			cells = [String(entry.order), entry.display_name, entry.rank,
				DemonCompendium.summon_cost(entry)]
		_set_cells(row, cells)
		if not known:
			_grey(row, "Not yet recorded.")
		elif DemonCompendium.why_not_summon(entry) != "":
			row.set_custom_color(COST_COLUMN, unavailable_color)
			row.set_tooltip_text(COST_COLUMN, DemonCompendium.why_not_summon(entry))
	_highlight(focus)
	says.emit(book_prompt)


## Your demons, to record. Does not open when you have none.
func _show_register() -> void:
	var owned: Array[OwnedDemon] = DemonRoster.all_owned()
	if owned.is_empty():
		says.emit(no_demons_line)
		return
	_step = Step.REGISTER
	_step_label.text = "Record a demon"
	_start_list(REGISTER_COLUMNS)
	_rows = owned
	var root: TreeItem = _list.get_root()
	for index in owned.size():
		var entry: OwnedDemon = owned[index]
		var row: TreeItem = _list.create_item(root)
		row.set_metadata(0, index)
		_set_cells(row, [String(entry.species.order), entry.species.display_name,
			entry.species.rank, "Yes" if DemonCompendium.is_registered(entry.species) else ""])
	_highlight(null)
	says.emit(register_prompt)


func _start_list(titles: PackedStringArray) -> void:
	_list.clear()
	_list.columns = titles.size()
	for column in titles.size():
		_list.set_column_title(column, titles[column])
		_list.set_column_expand(column, true)
		_list.set_column_expand_ratio(column, COLUMN_RATIOS[column])
	_list.create_item()
	_show_gold()


func _set_cells(row: TreeItem, cells: Array) -> void:
	for column in cells.size():
		row.set_text(column, str(cells[column]))


## Makes a whole row unchoosable, with the reason as its tooltip.
func _grey(row: TreeItem, why: String) -> void:
	for column in _list.columns:
		row.set_selectable(column, false)
		row.set_custom_color(column, unavailable_color)
		row.set_tooltip_text(column, why)


static func _book_order(a: UnitDefinition, b: UnitDefinition) -> bool:
	if a.order != b.order:
		return String(a.order) < String(b.order)
	if a.rank != b.rank:
		return a.rank < b.rank
	return a.display_name < b.display_name


func _show_gold() -> void:
	_gold_label.text = "Gold: %d" % CurrencyManager.gold


## Highlights `wanted`'s row, or else the first row that can be chosen.
func _highlight(wanted: Object) -> void:
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


func _highlighted() -> Object:
	var row: TreeItem = _list.get_selected()
	return _rows[row.get_metadata(0)] if row else null


func _on_highlighted() -> void:
	var picked: Object = _highlighted()
	if picked is OwnedDemon:
		_sheet.show_demon(picked.species, picked)
	else:
		_sheet.show_demon(picked as UnitDefinition)
	_set_buttons()


func _set_buttons() -> void:
	var in_book: bool = _step == Step.BOOK
	_summon_button.visible = in_book
	_register_button.visible = in_book
	_record_button.visible = not in_book
	var picked: Object = _highlighted()
	_record_button.disabled = picked == null
	var why: String = "Nothing highlighted."
	if in_book and picked:
		why = DemonCompendium.why_not_summon(picked as UnitDefinition)
	_summon_button.disabled = why != ""
	_summon_button.tooltip_text = why


func _on_chosen() -> void:
	var picked: Object = _highlighted()
	if picked == null:
		return
	if _step == Step.REGISTER:
		var owned: OwnedDemon = picked
		var had_page: bool = DemonCompendium.register(owned)
		_show_book(owned.species)
		says.emit((rerecorded_line if had_page else recorded_line) % owned.species.display_name)
		return
	var species: UnitDefinition = picked
	var why: String = DemonCompendium.why_not_summon(species)
	if why != "":
		says.emit(cannot_summon_line % why)
		return
	_summoning = species
	_confirm.dialog_text = confirm_text % [species.display_name, DemonCompendium.summon_cost(species)]
	_confirm.popup_centered()
	# No is the default, as in the fusion menu: gold spent by a double
	# Enter is gold the player did not mean to spend.
	_confirm.get_cancel_button().grab_focus.call_deferred()


func _on_yes() -> void:
	var species: UnitDefinition = _summoning
	_summoning = null
	if species == null or DemonCompendium.summon(species) == null:
		_list.grab_focus()
		return
	_show_book(species)
	says.emit(summoned_line % species.display_name)
