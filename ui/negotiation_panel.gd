extends UIScreen
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
##
## hides_hud/blocks_input_below/closes_on_cancel are authored on this
## scene's instance in MainRoot.tscn (hides_hud=true,
## blocks_input_below=true, closes_on_cancel=false, same reasoning as
## dialogue_overlay.gd — see UIScreen's own header).

## Flat colors, not a StyleBox/icon — this project has no art budget for
## a real reaction-icon asset (same portrait-scarcity situation as the
## SMT race roster), so a plain ColorRect standing in for one is the
## right-sized version: still a real at-a-glance signal, zero new assets.
const MOOD_COLOR_POSITIVE: Color = Color(0.4, 0.75, 0.4)
const MOOD_COLOR_NEGATIVE: Color = Color(0.8, 0.4, 0.4)
const MOOD_COLOR_NEUTRAL: Color = Color(0.6, 0.6, 0.6)

@onready var _demon_label: RichTextLabel = $VBoxContainer/PanelContainer/MarginContainer/BodyVBox/HeaderRow/DemonLabel
@onready var _mood_indicator: ColorRect = %MoodIndicator
@onready var _line_text: RichTextLabel = $VBoxContainer/PanelContainer/MarginContainer/BodyVBox/LineText
@onready var _choices_text: RichTextLabel = $VBoxContainer/PanelContainer/MarginContainer/BodyVBox/ChoicesText

var _current_choices: Array[DialogueChoice] = []
## Set by _on_mood_note_shown, consumed by the very next _on_line_shown —
## SystemLog already carries mood_note_shown's text into the permanent
## log, but SystemLog's own panel lives under tactical_ui, which is
## hidden for as long as this panel is open (see _on_negotiation_started).
## A mood shift on a choice that CONTINUES the conversation would
## otherwise never be seen at all until well after the fact, so it rides
## along on the next line this panel shows instead of needing a Control
## of its own.
var _pending_mood_note: String = ""


func _ready() -> void:
	visible = false

	_choices_text.meta_clicked.connect(_on_choice_meta_clicked)

	NegotiationManager.negotiation_started.connect(_on_negotiation_started)
	NegotiationManager.line_shown.connect(_on_line_shown)
	NegotiationManager.choices_shown.connect(_on_choices_shown)
	NegotiationManager.negotiation_ended.connect(_on_negotiation_ended)
	NegotiationManager.mood_note_shown.connect(_on_mood_note_shown)


func _on_negotiation_started(demon: Unit) -> void:
	open()
	_demon_label.text = "[b]%s[/b] is willing to talk." % demon.get_display_name()
	_pending_mood_note = ""
	_mood_indicator.color = MOOD_COLOR_NEUTRAL


func _on_mood_note_shown(text: String) -> void:
	_pending_mood_note = text
	if NegotiationManager.current_mood > 0:
		_mood_indicator.color = MOOD_COLOR_POSITIVE
	elif NegotiationManager.current_mood < 0:
		_mood_indicator.color = MOOD_COLOR_NEGATIVE
	else:
		_mood_indicator.color = MOOD_COLOR_NEUTRAL


func _on_line_shown(text: String) -> void:
	var shown: String = NegotiationManager.format_text(text)
	if _pending_mood_note != "":
		shown += "\n\n[i][color=#999999]%s[/color][/i]" % _pending_mood_note
		_pending_mood_note = ""
	_line_text.text = shown


func _on_choices_shown(choices: Array[DialogueChoice]) -> void:
	_current_choices = choices
	var lines: Array[String] = []
	for i in choices.size():
		lines.append("[url=%d]%d. %s[/url]" % [i, i + 1, NegotiationManager.format_text(choices[i].text)])
	_choices_text.text = "\n".join(lines)


func _on_negotiation_ended(_outcome: int) -> void:
	close()


func _on_choice_meta_clicked(meta) -> void:
	NegotiationManager.choose(int(meta))
