extends UIScreen
## Full-history review panel for the current conversation — the piece
## that makes dialogue_overlay.gd's "current line only" on-screen display
## acceptable instead of a regression from the old always-visible
## scrollback. Reads the conversation's own transcript to build the full
## text on open, then stays live on its `changed` signal while it stays
## open — nothing here can drift out of sync with what was actually
## said, whether the log was already open when a line landed or not.
##
## Found via the "conversation_log" group (see _ready()) rather than a
## direct NodePath export — dialogue_overlay.gd's own Log button, and its
## _on_conversation_ended(), both need to reach this without holding a
## reference of their own. hides_hud/blocks_input_below stay at
## UIScreen's own defaults (false) — this is a secondary overlay on top
## of dialogue, which has already hidden the HUD and already blocks new
## screens from opening; closes_on_cancel stays true (default), so
## Escape closes it like any other open screen.

@onready var _text: RichTextLabel = $PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/RichTextLabel
@onready var _close_button: Button = $PanelContainer/MarginContainer/VBoxContainer/Header/CloseButton
@onready var _scroll: ScrollContainer = $PanelContainer/MarginContainer/VBoxContainer/ScrollContainer

## The conversation being followed — the latest one to begin, kept after
## it ends so the log can still be reread until the next one starts.
var _conversation: Conversation = null
## How many of its transcript entries are already in the text.
var _seen: int = 0


func _ready() -> void:
	visible = false
	add_to_group("conversation_log")
	_close_button.pressed.connect(close)
	visibility_changed.connect(_on_visibility_changed)
	Conversations.follow(self, _on_conversation_began)


## A conversation can outlive this widget, so leaving its `changed`
## connected would fire into a freed node. The autoload's `began` is
## undone by Conversations.follow itself. Same recorded bug class as
## refcounted_component_autoload_signal_leak.md, just a Control instead of
## a RefCounted component.
func _exit_tree() -> void:
	_release()


## Every kind of conversation is followed — a negotiation's transcript is
## as real as a dialogue's — even though only the dialogue band offers a
## button to open this.
func _on_conversation_began(c: Conversation) -> void:
	_release()
	_conversation = c
	c.changed.connect(_on_changed)
	# Closed, nothing is drawn: opening rebuilds from the whole transcript.
	if visible:
		_rebuild()


func _release() -> void:
	if _conversation and _conversation.changed.is_connected(_on_changed):
		_conversation.changed.disconnect(_on_changed)


func _on_visibility_changed() -> void:
	if visible:
		_rebuild()


func _rebuild() -> void:
	var parts: PackedStringArray = []
	if _conversation:
		for entry in _conversation.transcript:
			parts.append(DialogueFormat.log_bbcode(entry))
		_seen = _conversation.transcript.size()
	else:
		_seen = 0
	_text.text = "\n\n".join(parts)
	if visible:
		_scroll_to_bottom()


## Incremental rather than a full rebuild — only the entries recorded
## since the last change are appended, styled by DialogueFormat.log_bbcode
## so this file never has to know how a line differs from an aside. Only
## runs while open; opening rebuilds from the whole transcript anyway.
func _on_changed() -> void:
	if not visible or _conversation == null:
		return
	var added: bool = false
	while _seen < _conversation.transcript.size():
		if _text.text != "":
			_text.text += "\n\n"
		_text.text += DialogueFormat.log_bbcode(_conversation.transcript[_seen])
		_seen += 1
		added = true
	if added:
		_scroll_to_bottom()


func _scroll_to_bottom() -> void:
	# One frame late — the RichTextLabel/ScrollContainer haven't re-laid-out
	# with the new text yet on the same frame it's assigned, so
	# get_v_scroll_bar().max_value is still the OLD content height here.
	await get_tree().process_frame
	if is_instance_valid(_scroll):
		_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)
