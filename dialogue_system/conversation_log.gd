extends Control
## Full-history review panel for the current conversation — the piece
## that makes dialogue_overlay.gd's "current line only" on-screen display
## acceptable instead of a regression from the old always-visible
## scrollback. Reads DialogueManager.transcript directly whenever it
## becomes visible rather than keeping its own copy — nothing here can
## drift out of sync with what was actually said.

@onready var _text: RichTextLabel = $PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/RichTextLabel
@onready var _close_button: Button = $PanelContainer/MarginContainer/VBoxContainer/Header/CloseButton


func _ready() -> void:
	visible = false
	_close_button.pressed.connect(func(): visible = false)
	visibility_changed.connect(_on_visibility_changed)


func _on_visibility_changed() -> void:
	if visible:
		_text.text = "\n\n".join(DialogueManager.transcript)
