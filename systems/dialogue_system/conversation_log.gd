extends UIScreen
## Full-history review panel for the current conversation — the piece
## that makes dialogue_overlay.gd's "current line only" on-screen display
## acceptable instead of a regression from the old always-visible
## scrollback. Reads DialogueManager.transcript directly to build the full
## text on open, then stays live via DialogueManager.line_shown while it
## stays open — nothing here can drift out of sync with what was actually
## said, whether the log was already open when a line landed or not.
##
## Found via the "conversation_log" group (see _ready()) rather than a
## direct NodePath export — dialogue_overlay.gd's own Log button, and its
## _on_dialogue_ended(), both need to reach this without holding a
## reference of their own. hides_hud/blocks_input_below stay at
## UIScreen's own defaults (false) — this is a secondary overlay on top
## of dialogue, which has already hidden the HUD and already blocks new
## screens from opening; closes_on_cancel stays true (default), so
## Escape closes it like any other open screen.

@onready var _text: RichTextLabel = $PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/RichTextLabel
@onready var _close_button: Button = $PanelContainer/MarginContainer/VBoxContainer/Header/CloseButton
@onready var _scroll: ScrollContainer = $PanelContainer/MarginContainer/VBoxContainer/ScrollContainer


func _ready() -> void:
	visible = false
	add_to_group("conversation_log")
	_close_button.pressed.connect(close)
	visibility_changed.connect(_on_visibility_changed)
	DialogueManager.line_shown.connect(_on_line_shown)


## Undone in _exit_tree — DialogueManager is an autoload that outlives this
## widget, so leaving this connected would fire into a freed node the next
## time a line is recorded. Same recorded bug class as
## refcounted_component_autoload_signal_leak.md, just a Control instead of
## a RefCounted component.
func _exit_tree() -> void:
	if DialogueManager.line_shown.is_connected(_on_line_shown):
		DialogueManager.line_shown.disconnect(_on_line_shown)


func _on_visibility_changed() -> void:
	if visible:
		_text.text = "\n\n".join(DialogueManager.transcript)
		_scroll_to_bottom()


## Incremental rather than a full rebuild — record_line() (see
## dialogue_manager.gd) always appends to transcript BEFORE emitting this
## signal, so transcript[-1] is exactly the formatted entry (bold speaker
## line or dimmed-italic echo, see DialogueFormat.speaker_line vs the
## dim/italic BBCode record_line wraps echo lines in) this line just added
## — reusing DialogueManager's own formatting instead of re-deriving it
## here keeps this file from needing to know that rule at all. Only runs
## while open; a rebuild already happens on _on_visibility_changed when
## the log is opened, so a line recorded while closed needs no work here.
func _on_line_shown(_text_arg: String, _speaker_token: String) -> void:
	if not visible:
		return
	if _text.text != "":
		_text.text += "\n\n"
	_text.text += DialogueManager.transcript.back()
	_scroll_to_bottom()


func _scroll_to_bottom() -> void:
	# One frame late — the RichTextLabel/ScrollContainer haven't re-laid-out
	# with the new text yet on the same frame it's assigned, so
	# get_v_scroll_bar().max_value is still the OLD content height here.
	await get_tree().process_frame
	if is_instance_valid(_scroll):
		_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)
