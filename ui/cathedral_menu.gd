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
## off, which is also why it does not go through DialogueManager and does
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

@export var party_overview: PartyOverview

@onready var _fuse_button: Button = %FuseButton
@onready var _compendium_button: Button = %CompendiumButton
@onready var _talk_button: Button = %TalkButton
@onready var _leave_button: Button = %LeaveButton
@onready var _speaker_line: Label = %SpeakerLine

var _line_index: int = 0


func _ready() -> void:
	_fuse_button.pressed.connect(_on_fuse)
	_compendium_button.pressed.connect(_on_compendium)
	_talk_button.pressed.connect(_on_talk)
	_leave_button.pressed.connect(_on_leave)
	_speaker_line.text = LINES[0]


## Called by the area when the player arrives, so the greeting is the
## greeting rather than wherever the rotation happened to be left.
func present() -> void:
	_line_index = 0
	_speaker_line.text = LINES[0]
	open()


func _on_fuse() -> void:
	if party_overview:
		party_overview.open_on_tab("demons")


func _on_compendium() -> void:
	# The same screen for now. The tab holds both browsing and fusing, and
	# splitting them into two views is presentation work with no mechanism
	# behind it yet.
	if party_overview:
		party_overview.open_on_tab("demons")


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
	close()
	WorldManager.load_area(&"overworld")
