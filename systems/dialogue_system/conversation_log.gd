extends UIScreen
## Full-history review panel for the current conversation — the piece
## that makes dialogue_overlay.gd's "current line only" on-screen display
## acceptable instead of a regression from the old always-visible
## scrollback. Reads DialogueManager.transcript directly whenever it
## becomes visible rather than keeping its own copy — nothing here can
## drift out of sync with what was actually said.
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


func _ready() -> void:
	visible = false
	add_to_group("conversation_log")
	_close_button.pressed.connect(close)
	visibility_changed.connect(_on_visibility_changed)


func _on_visibility_changed() -> void:
	if visible:
		_text.text = "\n\n".join(DialogueManager.transcript)
