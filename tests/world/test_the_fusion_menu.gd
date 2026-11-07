extends AiTestCase
## The Cathedral's fusion menu: two lists, a preview, and one question.
##
## What it must get right is what a player could lose demons to. A pairing
## that makes nothing cannot be chosen at all; the "are you sure?" starts
## on No, so Enter twice does not spend two demons; cancel steps back one
## list at a time; and yes really does fuse the two that were shown.
##
## Everything is asserted on what is RENDERED (is_visible_in_tree), not on
## what a manager believes is open — this project once shipped a green
## suite over panels nobody could see.

const DEMON_A := "res://data/units/demons/test_pixie.tres"
const DEMON_B := "res://data/units/demons/test_wolf.tres"

var _menu: CathedralMenu
var _fusion: FusionMenu
var _saved_roster: Dictionary
var _confirmed: Array = []


func run() -> void:
	_saved_roster = DemonRoster.save_state()
	DemonRoster.load_state({})
	_menu = (load("res://ui/cathedral_menu.tscn") as PackedScene).instantiate()
	_root.add_child(_menu)
	await get_tree().process_frame
	_fusion = _menu.get_node("%FusionMenu") as FusionMenu
	_fusion.fusion_confirmed.connect(func(a: OwnedDemon, b: OwnedDemon) -> void: _confirmed = [a, b])
	_menu.present()

	await _one_demon_is_not_a_fusion()
	var species_a: UnitDefinition = load(DEMON_A)
	var species_b: UnitDefinition = load(DEMON_B)
	var dud: UnitDefinition = _makes_nothing_with(species_a)
	if species_a == null or species_b == null or dud == null:
		check("SETUP: a pair that fuses and a demon that fuses with neither", false,
			"a=%s b=%s dud=%s" % [species_a, species_b, dud])
		_cleanup()
		return
	if FusionRitual.preview(_owned(species_a), _owned(species_b)) == null:
		check("SETUP: pixie and wolf fuse", false)
		_cleanup()
		return

	var a: OwnedDemon = DemonRoster.recruit(species_a)
	var b: OwnedDemon = DemonRoster.recruit(species_b)
	DemonRoster.recruit(dud)
	await _the_lists(a, b)
	await _cancel_steps_back(a)
	await _yes_fuses_what_was_shown(a, b)
	_cleanup()


func _one_demon_is_not_a_fusion() -> void:
	DemonRoster.recruit(load(DEMON_A))
	_menu.get_node("%FuseButton").pressed.emit()
	await get_tree().process_frame
	check("with one demon, Fuse does not open the menu",
		not _fusion.is_visible_in_tree(),
		"the menu opened with nothing to pair")
	check("and the Minister says why",
		_line() == _fusion.too_few_line,
		"the line was '%s'" % _line())
	DemonRoster.load_state({})


func _the_lists(a: OwnedDemon, b: OwnedDemon) -> void:
	_menu.get_node("%FuseButton").pressed.emit()
	await get_tree().process_frame
	check("Fuse opens the fusion menu, on screen",
		_fusion.is_visible_in_tree(),
		"the menu is not visible in the tree")
	check("and the option list steps aside",
		not (_menu.get_node("%Options") as Control).is_visible_in_tree(),
		"the Fuse/Compendium/Talk/Leave list is still drawn under the fusion menu")
	check("the first list is the whole roster",
		_rows().size() == 3,
		"%d rows for 3 demons" % _rows().size())

	_choose(a)
	await get_tree().process_frame
	check("choosing one moves to the second list",
		_fusion.step() == FusionMenu.Step.SECOND,
		"still on step %s" % FusionMenu.Step.keys()[_fusion.step()])
	var rows: Array[TreeItem] = _rows()
	check("which leaves out the first pick",
		rows.size() == 2,
		"%d rows; the first pick is offered as its own partner" % rows.size())

	var result: UnitDefinition = FusionRitual.preview(a, b)
	var partner: TreeItem = _row_named(b.species.display_name)
	var dud: TreeItem = null
	for row in rows:
		if row != partner:
			dud = row
	check("a pair that fuses can be chosen, and names its result",
		partner != null and partner.is_selectable(0) and partner.get_text(4) == result.display_name,
		"row=%s result column='%s'" % [partner, partner.get_text(4) if partner else ""])
	check("a pair that makes nothing cannot be chosen",
		dud != null and not dud.is_selectable(0),
		"the dud row is selectable, so the player can pick a pair and be told no")

	var result_sheet: DemonSheet = _fusion.get_node("%ResultSheet")
	var result_name: Label = result_sheet.get_node("%NameLabel")
	check("the Result tab shows what the highlighted pair makes",
		result_name.is_visible_in_tree() and result_name.text == result.display_name,
		"visible=%s text='%s'" % [result_name.is_visible_in_tree(), result_name.text])

	_choose(b)
	await get_tree().process_frame
	await get_tree().process_frame
	var confirm: ConfirmationDialog = _fusion.get_node("%Confirm")
	check("choosing the second asks first",
		confirm.visible,
		"no confirmation was shown")
	check("and the answer starts on No",
		confirm.get_cancel_button().has_focus(),
		"focus is on %s, so a second Enter fuses" % confirm.get_viewport().gui_get_focus_owner())
	confirm.get_cancel_button().pressed.emit()
	await get_tree().process_frame
	check("No leaves the roster alone",
		_confirmed.is_empty() and DemonRoster.is_owned(a) and DemonRoster.is_owned(b),
		"the fusion went through")


func _cancel_steps_back(a: OwnedDemon) -> void:
	_cancel()
	await get_tree().process_frame
	check("cancel from the second list goes back to the first",
		_fusion.is_visible_in_tree() and _fusion.step() == FusionMenu.Step.FIRST,
		"visible=%s step=%s" % [_fusion.is_visible_in_tree(), FusionMenu.Step.keys()[_fusion.step()]])
	var highlighted: TreeItem = (_fusion.get_node("%DemonList") as Tree).get_selected()
	check("with the first pick still highlighted",
		highlighted != null and highlighted.get_text(1) == a.species.display_name,
		"highlighted %s" % (highlighted.get_text(1) if highlighted else "nothing"))
	_cancel()
	await get_tree().process_frame
	check("and cancel again leaves the fusion menu",
		not _fusion.is_visible_in_tree(),
		"the fusion menu is still drawn")
	check("putting the option list back",
		(_menu.get_node("%Options") as Control).is_visible_in_tree(),
		"the Cathedral shows no options, and the room has no other way out")


func _yes_fuses_what_was_shown(a: OwnedDemon, b: OwnedDemon) -> void:
	var result: UnitDefinition = FusionRitual.preview(a, b)
	_menu.get_node("%FuseButton").pressed.emit()
	await get_tree().process_frame
	_choose(a)
	await get_tree().process_frame
	_choose(b)
	await get_tree().process_frame
	var confirm: ConfirmationDialog = _fusion.get_node("%Confirm")
	confirm.get_ok_button().pressed.emit()
	for i in 5:
		await get_tree().process_frame
	check("Yes reports the two that were chosen",
		_confirmed.size() == 2 and _confirmed[0] == a and _confirmed[1] == b,
		"reported %s" % str(_confirmed))
	var born: bool = DemonRoster.all_owned().any(
		func(owned: OwnedDemon) -> bool: return owned.species == result)
	check("and the Cathedral fuses them",
		not DemonRoster.is_owned(a) and not DemonRoster.is_owned(b) and born,
		"a owned=%s b owned=%s result born=%s" % [
			DemonRoster.is_owned(a), DemonRoster.is_owned(b), born])
	check("with both menus out of the way of the cutscene",
		not _fusion.is_visible_in_tree() and not (_menu.get_node("%Options") as Control).is_visible_in_tree(),
		"a menu is still drawn over the room")


## A species that makes nothing with `species`.
func _makes_nothing_with(species: UnitDefinition) -> UnitDefinition:
	if species == null:
		return null
	for other in SpawnableUnitDatabase.get_all():
		if other != species and other.order != &"" and \
				FusionRitual.preview(_owned(species), _owned(other)) == null:
			return other
	return null


func _owned(species: UnitDefinition) -> OwnedDemon:
	var owned := OwnedDemon.new()
	owned.species = species
	return owned


func _rows() -> Array[TreeItem]:
	return (_fusion.get_node("%DemonList") as Tree).get_root().get_children()


func _row_named(display_name: String) -> TreeItem:
	for row in _rows():
		if row.get_text(1) == display_name:
			return row
	return null


## Highlights a demon's row and presses Enter on it, as a player would.
func _choose(owned: OwnedDemon) -> void:
	var row: TreeItem = _row_named(owned.species.display_name)
	if row == null:
		return
	row.select(0)
	var tree: Tree = _fusion.get_node("%DemonList")
	tree.item_activated.emit()


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
