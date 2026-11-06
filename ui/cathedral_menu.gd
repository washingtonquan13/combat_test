class_name CathedralMenu
extends UIScreen
## The Cathedral of Shadows' interface: a list of options, with whatever
## the Minister is saying underneath it.
##
## A MENU, NOT A CONVERSATION. An earlier proposal made these four options
## dialogue choices, which was wrong — a dialogue advances through nodes
## and ends, and this does neither. It stands while you are in the room:
## you pick Fuse, the fusion happens, and you come back to the same list.
## The Minister's line is flavour beside it, not a node the options hang
## off, which is also why it does not go through Conversations and does
## not put the game in DIALOGUE mode.
##
## Deliberately does NOT close on cancel. It is the only interface in a
## room with no player character, so dismissing it would leave nothing to
## press — the soft-lock this room's whole design has to avoid. Leave is
## the way out, and it is always on the list.

## What the Minister says when you arrive, and when you ask him to talk.
## Rotates rather than randomises so pressing Talk twice never repeats.
const LINES: PackedStringArray = [
	"This is the Cathedral of Shadows... What is your bidding?",
	"Two become one. What is lost is not mourned here.",
	"The moon decides more than you know.",
	"Bring me what you no longer need, and I will make it something else.",
]
## What the Minister says when you come back to the list after a fusion.
const AFTER_FUSION_LINE: String = "What will you do?"

@onready var _fuse_button: Button = %FuseButton
@onready var _compendium_button: Button = %CompendiumButton
@onready var _talk_button: Button = %TalkButton
@onready var _leave_button: Button = %LeaveButton
@onready var _speaker_line: Label = %SpeakerLine
@onready var _options: Control = %Options
@onready var _fusion_menu: FusionMenu = %FusionMenu
@onready var _compendium_menu: CompendiumMenu = %CompendiumMenu

var _line_index: int = 0


func _ready() -> void:
	_fuse_button.pressed.connect(_on_fuse)
	_compendium_button.pressed.connect(_on_compendium)
	_talk_button.pressed.connect(_on_talk)
	_leave_button.pressed.connect(_on_leave)
	_speaker_line.text = LINES[0]
	_fusion_menu.fusion_confirmed.connect(_on_fusion_confirmed)
	# The option list steps aside while a sub-menu is up, as in the
	# reference. Tied to the sub-menus' visibility so every way one closes
	# puts the list back.
	for menu in [_fusion_menu, _compendium_menu]:
		menu.says.connect(func(line: String) -> void: _speaker_line.text = line)
		menu.visibility_changed.connect(_update_options)


## Called by the area when the player arrives, so the greeting is the
## greeting rather than wherever the rotation happened to be left.
## `line` replaces the greeting, for coming back after a fusion.
func present(line: String = "") -> void:
	_line_index = 0
	_speaker_line.text = line if line != "" else LINES[0]
	open()


func _on_fuse() -> void:
	_fusion_menu.begin()


## The fusion itself, then this menu back.
##
## Both menus close first: the cutscene plays in this room, and a list
## over it would hide it. The menu only comes back if the player is still
## in the room the fusion started in. A world loaded mid-scene (a load
## from the escape menu) means this room's own arrival presents the menu,
## if it is this room at all.
func _on_fusion_confirmed(first: OwnedDemon, second: OwnedDemon) -> void:
	var room: Node = WorldManager.spawn_parent()
	close()
	await FusionRitual.perform(first, second)
	if is_instance_valid(room) and room.is_inside_tree() and WorldManager.spawn_parent() == room:
		present(AFTER_FUSION_LINE)


func _update_options() -> void:
	_options.visible = not (_fusion_menu.visible or _compendium_menu.visible)


func _on_compendium() -> void:
	_compendium_menu.begin()


func _on_talk() -> void:
	_line_index = (_line_index + 1) % LINES.size()
	_speaker_line.text = LINES[_line_index]


## The way out, and the reason this screen cannot be dismissed.
##
## Travels rather than closing: leaving a menu-room means leaving the room.
## The overworld is where the cathedral is reached from, and the arrival
## point is derived from the overworld's own door back here — nothing has
## to remember the way.
func _on_leave() -> void:
	WorldManager.travel_area(&"overworld")
