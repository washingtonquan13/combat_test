extends AiTestCase
## The Cathedral's Demonic Compendium: a book of pages, a list to record
## from, and one question before gold is spent.
##
## What it must get right is what a player could lose gold or a page to. A
## blank page cannot be summoned; a page you cannot afford can be read but
## not bought; "are you sure?" starts on No; yes charges exactly the cost
## shown and adds exactly one demon; and a page survives the demon it was
## recorded from being fused away. Plus: the book is saved.
##
## Everything is asserted on what is RENDERED (is_visible_in_tree), not on
## what a manager believes is open.

const PIXIE := "res://data/units/demons/test_pixie.tres"

var _menu: CathedralMenu
var _book: CompendiumMenu
var _saved_roster: Dictionary
var _saved_book: Dictionary
var _saved_gold: Dictionary


func run() -> void:
	_saved_roster = DemonRoster.save_state()
	_saved_book = DemonCompendium.save_state()
	_saved_gold = CurrencyManager.save_state()
	DemonRoster.load_state({})
	DemonCompendium.load_state({})
	_menu = (load("res://ui/cathedral_menu.tscn") as PackedScene).instantiate()
	_root.add_child(_menu)
	await get_tree().process_frame
	_book = _menu.get_node("%CompendiumMenu") as CompendiumMenu
	_menu.present()

	var pixie: UnitDefinition = load(PIXIE)
	if pixie == null or not DemonDatabase.get_all().has(pixie):
		check("SETUP: test_pixie is in the demon database", false)
		_cleanup()
		return

	await _a_blank_book(pixie)
	await _nothing_to_record()
	var owned: OwnedDemon = DemonRoster.recruit(pixie)
	await _recording(owned)
	await _summoning(pixie)
	await _cancel_steps_back()
	_the_book_is_saved(owned)
	_cleanup()


func _a_blank_book(pixie: UnitDefinition) -> void:
	_press("%CompendiumButton")
	await get_tree().process_frame
	check("Demonic Compendium opens the book, on screen",
		_book.is_visible_in_tree() and _book.step() == CompendiumMenu.Step.BOOK,
		"visible=%s" % _book.is_visible_in_tree())
	check("and the option list steps aside",
		not _options().is_visible_in_tree(),
		"the Fuse/Compendium/Talk/Leave list is still drawn under the book")
	check("the book has a page for every demon",
		_rows().size() == DemonDatabase.get_all().size(),
		"%d rows for %d demons" % [_rows().size(), DemonDatabase.get_all().size()])
	var blank: TreeItem = _row_of(pixie)
	check("an unrecorded page is blank and cannot be highlighted",
		blank != null and blank.get_text(1) == _book.unknown_name and not blank.is_selectable(0),
		"row=%s name='%s'" % [blank, blank.get_text(1) if blank else ""])
	check("so with nothing recorded, Summon is disabled",
		(_book.get_node("%SummonButton") as Button).disabled,
		"Summon is pressable over a blank book")


func _nothing_to_record() -> void:
	_press("%RegisterButton")
	await get_tree().process_frame
	check("with no demons, Record does not leave the book",
		_book.step() == CompendiumMenu.Step.BOOK,
		"the register list opened empty")
	check("and the Minister says why",
		_line() == _book.no_demons_line,
		"the line was '%s'" % _line())


func _recording(owned: OwnedDemon) -> void:
	_press("%RegisterButton")
	await get_tree().process_frame
	check("Record a demon lists the roster",
		_book.step() == CompendiumMenu.Step.REGISTER and _rows().size() == 1,
		"step=%s rows=%d" % [CompendiumMenu.Step.keys()[_book.step()], _rows().size()])
	_activate(owned.species)
	await get_tree().process_frame
	var page: TreeItem = _row_of(owned.species)
	check("recording returns to the book, on that page",
		_book.step() == CompendiumMenu.Step.BOOK and page != null and page.is_selected(0),
		"step=%s page selected=%s" % [
			CompendiumMenu.Step.keys()[_book.step()], page.is_selected(0) if page else false])
	check("which is now filled in",
		page != null and page.get_text(1) == owned.species.display_name and page.is_selectable(0),
		"name='%s'" % (page.get_text(1) if page else ""))
	check("and the Minister says it was recorded",
		_line() == _book.recorded_line % owned.species.display_name,
		"the line was '%s'" % _line())
	var name_label: Label = _book.get_node("%Sheet").get_node("%NameLabel")
	check("the sheet shows the highlighted page",
		name_label.is_visible_in_tree() and name_label.text == owned.species.display_name,
		"visible=%s text='%s'" % [name_label.is_visible_in_tree(), name_label.text])

	_press("%RegisterButton")
	await get_tree().process_frame
	_activate(owned.species)
	await get_tree().process_frame
	check("recording the same species again rewrites the page",
		_line() == _book.rerecorded_line % owned.species.display_name,
		"the line was '%s'" % _line())


func _summoning(pixie: UnitDefinition) -> void:
	var cost: int = DemonCompendium.summon_cost(pixie)
	var roster_before: int = DemonRoster.all_owned().size()

	CurrencyManager.load_state({"gold": cost - 1})
	_book.begin()
	await get_tree().process_frame
	var page: TreeItem = _row_of(pixie)
	check("a page you cannot afford can still be read",
		page != null and page.is_selected(0),
		"the page cannot be highlighted")
	check("but Summon is disabled",
		(_book.get_node("%SummonButton") as Button).disabled,
		"Summon is pressable with %d gold for a %d-gold demon" % [cost - 1, cost])
	_activate(pixie)
	await get_tree().process_frame
	check("and choosing it anyway spends nothing",
		CurrencyManager.gold == cost - 1 and DemonRoster.all_owned().size() == roster_before
			and not _confirm().visible,
		"gold=%d roster=%d confirm=%s" % [
			CurrencyManager.gold, DemonRoster.all_owned().size(), _confirm().visible])

	CurrencyManager.load_state({"gold": cost + 7})
	_book.begin()
	await get_tree().process_frame
	_activate(pixie)
	await get_tree().process_frame
	await get_tree().process_frame
	check("choosing a page you can afford asks first",
		_confirm().visible,
		"no confirmation was shown")
	check("and the answer starts on No",
		_confirm().get_cancel_button().has_focus(),
		"focus is on %s, so a second Enter spends gold" % get_viewport().gui_get_focus_owner())
	_confirm().get_cancel_button().pressed.emit()
	await get_tree().process_frame
	check("No spends nothing",
		CurrencyManager.gold == cost + 7 and DemonRoster.all_owned().size() == roster_before,
		"gold=%d roster=%d" % [CurrencyManager.gold, DemonRoster.all_owned().size()])

	_activate(pixie)
	await get_tree().process_frame
	_confirm().get_ok_button().pressed.emit()
	await get_tree().process_frame
	var newest: OwnedDemon = DemonRoster.all_owned().back()
	check("Yes charges exactly the cost shown",
		CurrencyManager.gold == 7,
		"%d gold left of %d after a %d-gold summon" % [CurrencyManager.gold, cost + 7, cost])
	check("and adds one demon of that species, whole",
		DemonRoster.all_owned().size() == roster_before + 1 and newest.species == pixie
			and newest.current_hp == pixie.max_hp,
		"roster %d -> %d, newest %s at %d HP" % [
			roster_before, DemonRoster.all_owned().size(), newest.species.display_name, newest.current_hp])
	check("and the Minister says so",
		_line() == _book.summoned_line % pixie.display_name,
		"the line was '%s'" % _line())

	for owned in DemonRoster.all_owned():
		DemonRoster.release(owned)
	check("a page outlives the demon it was recorded from",
		DemonCompendium.is_registered(pixie),
		"releasing every pixie erased the page")


func _cancel_steps_back() -> void:
	DemonRoster.recruit(load(PIXIE))
	_book.begin()
	_press("%RegisterButton")
	await get_tree().process_frame
	_cancel()
	await get_tree().process_frame
	check("cancel from the record list goes back to the book",
		_book.is_visible_in_tree() and _book.step() == CompendiumMenu.Step.BOOK,
		"visible=%s step=%s" % [_book.is_visible_in_tree(), CompendiumMenu.Step.keys()[_book.step()]])
	_cancel()
	await get_tree().process_frame
	check("and cancel again leaves the book",
		not _book.is_visible_in_tree(),
		"the book is still drawn")
	check("putting the option list back",
		_options().is_visible_in_tree(),
		"the Cathedral shows no options, and the room has no other way out")


func _the_book_is_saved(owned: OwnedDemon) -> void:
	var saved: Dictionary = DemonCompendium.save_state()
	DemonCompendium.load_state({})
	check("a new game's empty section empties the book",
		not DemonCompendium.is_registered(owned.species),
		"the page survived load_state({})")
	DemonCompendium.load_state(saved)
	check("and loading the save puts the page back",
		DemonCompendium.is_registered(owned.species),
		"saved=%s" % saved)


func _options() -> Control:
	return _menu.get_node("%Options") as Control


func _confirm() -> ConfirmationDialog:
	return _book.get_node("%Confirm") as ConfirmationDialog


func _rows() -> Array[TreeItem]:
	return (_book.get_node("%DemonList") as Tree).get_root().get_children()


## The row showing this species: a page in the book, or an owned demon of
## that species in the record list. Found through the row's metadata, not
## its text, because a blank page's text is the same for every species.
func _row_of(species: UnitDefinition) -> TreeItem:
	for row in _rows():
		var entry: Object = _book._rows[row.get_metadata(0)]
		if entry == species or (entry is OwnedDemon and entry.species == species):
			return row
	return null


## A button by unique name: the Cathedral's own, or one inside the book.
func _press(button: String) -> void:
	var found: Node = _menu.get_node_or_null(button)
	if found == null:
		found = _book.get_node(button)
	(found as Button).pressed.emit()


## Highlights a species' row and presses Enter on it, as a player would.
func _activate(species: UnitDefinition) -> void:
	var row: TreeItem = _row_of(species)
	if row == null:
		return
	row.select(0)
	(_book.get_node("%DemonList") as Tree).item_activated.emit()


func _cancel() -> void:
	var press := InputEventAction.new()
	press.action = &"ui_cancel"
	press.pressed = true
	get_viewport().push_input(press)


func _line() -> String:
	return (_menu.get_node("%SpeakerLine") as Label).text


func _cleanup() -> void:
	if is_instance_valid(_menu):
		UIStack.close_all()
		_menu.queue_free()
	DemonRoster.load_state(_saved_roster)
	DemonCompendium.load_state(_saved_book)
	CurrencyManager.load_state(_saved_gold)
