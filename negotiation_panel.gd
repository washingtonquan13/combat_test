extends Control
## Thin, reactive negotiation UI — purely a listener over
## NegotiationManager's signals, never touches its state directly, same
## "the manager owns state, this just renders" split as
## dialogue_overlay.gd. Mirrors that file's actual node-driven rendering
## closely (current line + a numbered [url=index] choice list via
## meta_clicked) now that negotiation is a real authored conversation,
## not a flat generic response list — but still NOT built on
## dialogue_overlay.gd/its scene, since this is the "different, lighter
## flow" negotiation was explicitly scoped to be, not a reskin of the
## full conversation system. No Continue button: DialogueNode.next_node_id
## is authored-but-never-read for negotiation content (see
## NegotiationManager._show_node) — a negotiation tree only ever ends via
## an explicit outcome choice, never a "keep going" beat.

@export var tactical_ui: Control

@onready var _demon_label: RichTextLabel = $VBoxContainer/PanelContainer/MarginContainer/BodyVBox/DemonLabel
@onready var _line_text: RichTextLabel = $VBoxContainer/PanelContainer/MarginContainer/BodyVBox/LineText
@onready var _choices_text: RichTextLabel = $VBoxContainer/PanelContainer/MarginContainer/BodyVBox/ChoicesText

var _current_choices: Array[DialogueChoice] = []


func _ready() -> void:
	visible = false

	_choices_text.meta_clicked.connect(_on_choice_meta_clicked)

	NegotiationManager.negotiation_started.connect(_on_negotiation_started)
	NegotiationManager.line_shown.connect(_on_line_shown)
	NegotiationManager.choices_shown.connect(_on_choices_shown)
	NegotiationManager.negotiation_ended.connect(_on_negotiation_ended)


func _on_negotiation_started(demon: Unit) -> void:
	visible = true
	_demon_label.text = "[b]%s[/b] is willing to talk." % demon.name
	if tactical_ui:
		tactical_ui.visible = false


func _on_line_shown(text: String) -> void:
	_line_text.text = text


func _on_choices_shown(choices: Array[DialogueChoice]) -> void:
	_current_choices = choices
	var lines: Array[String] = []
	for i in choices.size():
		lines.append("[url=%d]%d. %s[/url]" % [i, i + 1, choices[i].text])
	_choices_text.text = "\n".join(lines)


func _on_negotiation_ended(_outcome: int) -> void:
	visible = false
	if tactical_ui:
		tactical_ui.visible = true


func _on_choice_meta_clicked(meta) -> void:
	NegotiationManager.choose(int(meta))
