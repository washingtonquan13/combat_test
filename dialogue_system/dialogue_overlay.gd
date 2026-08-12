extends Control
## Thin, subtitle-style dialogue UI — deliberately NOT the old GURPS-
## project's DialogueBox (dual static portraits, heavy nested panels, an
## always-visible scrolling transcript). The cinematic camera IS the
## visual now; this is just enough text to follow along: speaker name,
## current line, response options. Full history lives in
## DialogueManager.transcript and is reviewed via conversation_log (the
## Log button), not shown here.
##
## Response options render as ONE RichTextLabel with [url=index]...[/url]
## per choice rather than a Button-per-choice component (the old
## system's DialogueChoiceButton) — BBCode tags (alignment color, skill
## tag; see DialogueFormat) already need RichTextLabel to render at all,
## and a single clickable rich-text list is simpler than a
## Button+RichTextLabel composite per choice, with no container-sizing
## fight between the two.

@export var conversation_log: Control

@onready var _speaker_label: Label = $MarginContainer/VBoxContainer/SpeakerLabel
@onready var _line_text: RichTextLabel = $MarginContainer/VBoxContainer/LineText
@onready var _choices_text: RichTextLabel = $MarginContainer/VBoxContainer/ChoicesText
@onready var _continue_button: Button = $MarginContainer/VBoxContainer/ContinueButton
@onready var _log_button: Button = $MarginContainer/VBoxContainer/LogButton

var _current_choices: Array[DialogueChoice] = []


func _ready() -> void:
	visible = false

	_choices_text.meta_clicked.connect(_on_choice_meta_clicked)
	_continue_button.pressed.connect(_on_continue_pressed)
	_log_button.pressed.connect(_on_log_pressed)

	DialogueManager.dialogue_started.connect(_on_dialogue_started)
	DialogueManager.line_shown.connect(_on_line_shown)
	DialogueManager.choices_shown.connect(_on_choices_shown)
	DialogueManager.dialogue_ended.connect(_on_dialogue_ended)


func _on_dialogue_started(_root: DialogueNode) -> void:
	visible = true
	_choices_text.text = ""
	_continue_button.visible = false


## speaker_token is "" for the smaller echo lines (alignment message,
## echoed response, skill check result) — the speaker label deliberately
## stays on whoever last had a real line rather than clearing, since
## those echoes are the player's own side of the conversation, not a
## new speaker taking over.
func _on_line_shown(text: String, speaker_token: String) -> void:
	_line_text.text = text
	if speaker_token == "":
		return
	var unit: Unit = DialogueManager.participants.get(speaker_token)
	_speaker_label.text = unit.name if unit else ""


func _on_choices_shown(choices: Array[DialogueChoice]) -> void:
	_current_choices = choices

	if choices.is_empty():
		_choices_text.text = ""
		_continue_button.visible = true
		_continue_button.text = "End Conversation" if DialogueManager.current_node.next_node_id == "" else "Continue"
		return

	_continue_button.visible = false
	var lines: Array[String] = []
	for i in choices.size():
		lines.append("[url=%d]%d. %s[/url]" % [i, i + 1, DialogueFormat.choice_label(choices[i])])
	_choices_text.text = "\n".join(lines)


func _on_dialogue_ended() -> void:
	visible = false
	if conversation_log:
		conversation_log.visible = false


func _on_choice_meta_clicked(meta) -> void:
	DialogueManager.choose(int(meta))


func _on_continue_pressed() -> void:
	DialogueManager.advance()


func _on_log_pressed() -> void:
	if conversation_log:
		conversation_log.visible = not conversation_log.visible
