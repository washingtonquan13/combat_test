extends CanvasLayer
## "LEVEL N" across the top of the screen when the party levels, with a
## button that opens the leader's level-up screen. Owned by Progression,
## so it works in any world without being placed in one. It fades on its
## own; the party overview's LEVEL UP button reaches every member later.
##
## Above the HUD and cinematics (layer 1-2), under ScreenFade (10), so a
## level gained mid-travel stays behind the black.

const SHOW_SECONDS: float = 8.0
const FADE_SECONDS: float = 0.4

@onready var _panel: PanelContainer = %Panel
@onready var _level_label: Label = %LevelLabel
@onready var _note: Label = %Note
@onready var _button: Button = %LevelUpButton
@onready var _hide_timer: Timer = %HideTimer

var _tween: Tween


func _ready() -> void:
	_panel.visible = false
	_button.pressed.connect(_on_level_up_pressed)
	_hide_timer.timeout.connect(_fade_out)


func show_level(level: int) -> void:
	_level_label.text = "LEVEL %d" % level
	_note.text = "Every party member has points to spend."
	_kill_tween()
	_panel.visible = true
	_panel.modulate.a = 0.0
	_tween = create_tween()
	_tween.tween_property(_panel, "modulate:a", 1.0, FADE_SECONDS)
	_hide_timer.start(SHOW_SECONDS)


func hide_now() -> void:
	_kill_tween()
	_hide_timer.stop()
	_panel.visible = false


func _fade_out() -> void:
	_kill_tween()
	_tween = create_tween()
	_tween.tween_property(_panel, "modulate:a", 0.0, FADE_SECONDS)
	_tween.tween_callback(hide_now)


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null


## A refusal ("Not during a fight.") replaces the note and restarts the
## timer, so it can be read.
func _on_level_up_pressed() -> void:
	var why: String = Progression.open_level_up(PartyManager.leader)
	if why.is_empty():
		hide_now()
		return
	_note.text = why
	_hide_timer.start(SHOW_SECONDS)
