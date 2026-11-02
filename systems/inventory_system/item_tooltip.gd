class_name ItemTooltip
extends PanelContainer
## The hover card Item._make_custom_tooltip shows: name in its rarity's
## colour above the item's art at twice its bag size with its sockets on
## it (the one place an equipped item's sockets show), what kind of item
## it is, then one line per attack row, stat
## modifier, socket count and rune. The layout is the scene's; this only
## fills it.

@onready var _name: Label = %Name
@onready var _kind: Label = %Kind
@onready var _details: VBoxContainer = %Details
@onready var _art_plate: PanelContainer = %ArtPlate
@onready var _art: TextureRect = %Art
@onready var _art_sockets: SocketOverlay = %ArtSockets

## Pixels per grid cell in the tooltip's art: twice the bag's 32.
const ART_CELL := 64.0


func show_item(item: ItemInstance) -> void:
	_art_plate.visible = item.definition.icon != null
	_art.texture = item.definition.icon
	_art.custom_minimum_size = Vector2(item.definition.width, item.definition.height) * ART_CELL
	_art_sockets.show_sockets(item, ART_CELL)
	_name.text = item.display_name()
	_name.add_theme_color_override("font_color", item.rarity_color())
	_kind.text = _kind_of(item)
	for row in item.attacks():
		var line := "%s: %s" % [row.label, row.describe_damage()]
		if row.to_hit_bonus != 0:
			line += ", %+d to hit" % row.to_hit_bonus
		_add(line)
	for modifier in item.stat_modifiers():
		_add(modifier.describe())
	if item.max_sockets() > 0:
		_add("Sockets: %d / %d" % [item.sockets, item.max_sockets()], Color(0.7, 0.7, 0.7))
	for rune in item.runes:
		var modifier: ItemModifier = rune.modifier_for(item)
		_add("%s: %s" % [rune.item_name, modifier.label if modifier else "—"], Color(0.9, 0.75, 0.35))


## What a tooltip with no item to show (a hand-placed Item) falls back to.
func set_text(text: String) -> void:
	_name.text = text
	_kind.hide()
	_art_plate.hide()


func _kind_of(item: ItemInstance) -> String:
	if item.gear_data:
		var kind: String = GearItem.SlotType.keys()[item.gear_data.slot_type].capitalize()
		if item.gear_data.weapon_data and item.gear_data.weapon_data.two_handed:
			kind += ", two-handed"
		return kind
	if item.definition is RuneItem:
		return "Rune — drag onto an item with a free socket"
	if item.definition is SocketTool:
		return "Currency — drag onto an item to add a socket"
	return "Item"


func _add(text: String, color: Color = Color(0.92, 0.92, 0.92)) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# A wrapping label measured before layout has no width and reports a
	# screen-tall height; pin the wrap width to the panel's inner width.
	label.custom_minimum_size.x = custom_minimum_size.x - 16
	label.add_theme_color_override("font_color", color)
	_details.add_child(label)
