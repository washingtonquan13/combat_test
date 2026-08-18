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
## The existing tactical HUD wrapper (main.tscn's TacticalUI Control) —
## hidden for the duration of a conversation, restored when it ends.
## Toggled here rather than TacticalUI reacting to DialogueManager
## itself, matching the conversation_log toggle right below: this script
## already owns "what the screen looks like during dialogue."
@export var tactical_ui: Control

@onready var _line_text: RichTextLabel = $VBoxContainer/ContentBox/InnerVBox/MarginContainer/BodyVBox/LineText
@onready var _choices_text: RichTextLabel = $VBoxContainer/ContentBox/InnerVBox/MarginContainer/BodyVBox/ChoicesText
@onready var _continue_button: Button = $VBoxContainer/HeaderBar/ContinueButton
@onready var _log_button: Button = $VBoxContainer/HeaderBar/LogButton

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
	DialogueManager.dice_roll_requested.connect(_on_dice_roll_requested)


func _on_dialogue_started(_root: DialogueNode) -> void:
	visible = true
	_choices_text.text = ""
	_continue_button.visible = false
	if tactical_ui:
		tactical_ui.visible = false


## speaker_token is "" for the smaller echo lines (alignment message,
## echoed response, skill check result) — shown as plain text, no name
## attached, same as they get no name in the log either (see
## DialogueManager.record_line). A real speaker gets DialogueFormat's
## shared "Name on its own bold line, then the text" treatment — the
## exact same formatting the log uses, so there's only one place that
## decides what "who said this" looks like, not a separate SpeakerLabel
## Control that has to stay position-synced with the line under it.
func _on_line_shown(text: String, speaker_token: String) -> void:
	if speaker_token == "":
		_line_text.text = text
		return
	var unit: Unit = DialogueManager.participants.get(speaker_token)
	var speaker_name: String = unit.name if unit else speaker_token.capitalize()
	_line_text.text = DialogueFormat.speaker_line(speaker_name, text)


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


## The choice that just resolved is already committed (used_choices is
## marked before DialogueManager.choose() even starts awaiting) — but
## the OLD choice list/Continue button are still the last thing
## choices_shown rendered, and stay clickable, for as long as the roll
## takes to play out underneath skill_check_dice_popup.gd. Without
## this, a second click during that window would call choose() again
## concurrently. Nothing needs to restore these — the resolution that's
## already running emits a fresh choices_shown/line_shown once it
## actually finishes, same as any other node transition.
func _on_dice_roll_requested(_skill_name: String, _roll: Dictionary) -> void:
	_choices_text.text = ""
	_continue_button.visible = false


func _on_dialogue_ended() -> void:
	visible = false
	if tactical_ui:
		tactical_ui.visible = true
	if conversation_log:
		conversation_log.visible = false


func _on_choice_meta_clicked(meta) -> void:
	DialogueManager.choose(int(meta))


func _on_continue_pressed() -> void:
	DialogueManager.advance()


func _on_log_pressed() -> void:
	if conversation_log:
		conversation_log.visible = not conversation_log.visible
