extends UIScreen
## Thin, reactive negotiation UI — it follows a conversation whose
## presentation is &"negotiation" and redraws from its snapshot() and new
## transcript entries on `changed`, never touching its state beyond
## choose(). Same "the conversation owns state, this just renders" split
## as dialogue_overlay.gd. Mirrors that file's node-driven rendering
## closely (current node text + a numbered [url=index] choice list via
## meta_clicked) — but still NOT built on dialogue_overlay.gd/its scene,
## since this is the "different, lighter flow" negotiation was explicitly
## scoped to be, not a reskin of the full conversation system. No Continue
## button: a negotiation tree only ever ends via an outcome effect, and a
## node with nothing left to choose ends through the tree's dead-end effect
## (see NegotiationOpeningEffect), so the built-in continue/end entry never
## appears here.
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

## The ids of the rows on screen, by row number — meta_clicked carries
## the row number, and this turns it back into the choice's stable id.
var _current_ids: Array[StringName] = []
## Set when a mood entry lands, consumed by the very next node this panel
## shows — SystemLog already carries the note into the permanent log (the
## negotiation echoes its transcript there), but SystemLog's own panel
## lives under tactical_ui, which is hidden for as long as this panel is
## open. A mood shift on a choice that CONTINUES the conversation would
## otherwise never be seen at all until well after the fact, so it rides
## along on the next node's text instead of needing a Control of its own.
var _pending_mood_note: String = ""
var _conversation: Conversation = null
var _seen: int = 0
var _shown_visit: int = -1


func _ready() -> void:
	visible = false

	_choices_text.meta_clicked.connect(_on_choice_meta_clicked)

	Conversations.follow(self, _on_conversation_began)


func _exit_tree() -> void:
	_release()


func _on_conversation_began(c: Conversation) -> void:
	if c.presentation != &"negotiation":
		return
	_release()
	_conversation = c
	_seen = 0
	_shown_visit = -1
	_current_ids.clear()
	open()
	var demon: Unit = c.cast.get("npc") as Unit
	_demon_label.text = "[b]%s[/b] is willing to talk." % (
		demon.get_display_name() if is_instance_valid(demon) else "The demon")
	_pending_mood_note = ""
	_mood_indicator.color = MOOD_COLOR_NEUTRAL
	c.changed.connect(_on_changed)
	_on_changed()


func _on_changed() -> void:
	var c: Conversation = _conversation
	if c == null:
		return
	if c.ended:
		_release()
		close()
		return

	while _seen < c.transcript.size():
		var entry: Dictionary = c.transcript[_seen]
		_seen += 1
		if entry.get("tag") == &"mood":
			_on_mood_note(entry)

	var snap: Dictionary = c.snapshot()
	if snap.visit != _shown_visit:
		_shown_visit = snap.visit
		_show_node(snap)


func _on_mood_note(entry: Dictionary) -> void:
	_pending_mood_note = entry.text
	var mood: int = entry.get("mood", 0)
	if mood > 0:
		_mood_indicator.color = MOOD_COLOR_POSITIVE
	elif mood < 0:
		_mood_indicator.color = MOOD_COLOR_NEGATIVE
	else:
		_mood_indicator.color = MOOD_COLOR_NEUTRAL


func _show_node(snap: Dictionary) -> void:
	var shown: String = snap.node_text
	if _pending_mood_note != "":
		shown += "\n\n[i][color=#999999]%s[/color][/i]" % _pending_mood_note
		_pending_mood_note = ""
	_line_text.text = shown

	_current_ids.clear()
	var lines: Array[String] = []
	for entry in snap.choices:
		if entry.get("builtin", false):
			continue
		var i: int = _current_ids.size()
		_current_ids.append(entry.id)
		lines.append("[url=%d]%d. %s[/url]" % [i, i + 1, entry.text])
	_choices_text.text = "\n".join(lines)


func _release() -> void:
	if _conversation and _conversation.changed.is_connected(_on_changed):
		_conversation.changed.disconnect(_on_changed)
	_conversation = null


func _on_choice_meta_clicked(meta) -> void:
	var row: int = int(meta)
	if _conversation and row >= 0 and row < _current_ids.size():
		_conversation.choose(_current_ids[row])
