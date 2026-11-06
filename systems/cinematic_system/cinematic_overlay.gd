class_name CinematicOverlay
extends UIScreen
## What a cutscene puts over the picture: letterbox bars, a subtitle band
## (speaker name and line), and a small prompt shown only while the scene
## is waiting for the player.
##
## A UIScreen, AND THAT IS HOW THE HUD GOES AWAY. hides_hud is set on the
## instance in MainRoot.tscn, so opening this screen takes the tactical HUD
## and the party rail down through UIStack's existing rule — derived from
## what is open, with no second owner of the HUD's visibility and nothing
## to restore by hand afterwards. It is also blocks_input_below, so no
## other screen opens over a running scene, and not closes_on_cancel,
## because Escape during a cutscene means skip (the director eats it).
##
## Driven by CinematicDirector, which registers it at boot (main_root.gd)
## and calls enter()/leave() around every mounted scene. Beats call
## show_line()/clear_line(); the director calls show_prompt() every frame
## from whether the stage is waiting. Nothing here decides anything.
##
## On its own CanvasLayer above the HUD's, so the bars cover whatever is
## left on screen underneath (a dialogue panel, say) rather than the other
## way round.

## How much of the screen height each bar takes, fully in.
const BAR_FRACTION: float = 0.11
## Quick on purpose: the bars announce the scene, they are not a scene.
const BAR_SECONDS: float = 0.25

@onready var _top: Control = $TopBar
@onready var _bottom: Control = $BottomBar
@onready var _subtitle: Control = $Subtitle
@onready var _speaker: Label = $Subtitle/Speaker
@onready var _line: Label = $Subtitle/Line
@onready var _prompt: Control = $Prompt

var _tween: Tween = null
var _bars: float = 0.0


func _ready() -> void:
	_set_bars(0.0)
	clear_line()
	show_prompt(false)


## Opens the screen and brings the bars in. Safe while already in — a
## second scene starting while the first's bars are still leaving takes
## them straight back.
func enter() -> void:
	_kill_tween()
	open()
	_tween = create_tween()
	_tween.tween_method(_set_bars, _bars, 1.0, BAR_SECONDS * (1.0 - _bars))


## Takes the bars out, then closes. The HUD comes back on close, so for the
## length of the tween the picture is still framed as a scene.
func leave() -> void:
	clear_line()
	show_prompt(false)
	_kill_tween()
	if not UIStack.is_open(self):
		_set_bars(0.0)
		return
	_tween = create_tween()
	_tween.tween_method(_set_bars, _bars, 0.0, BAR_SECONDS * _bars)
	_tween.tween_callback(close)


func show_line(speaker: String, text: String) -> void:
	_speaker.text = speaker
	_speaker.visible = speaker != ""
	_line.text = text
	_subtitle.visible = text != ""


func clear_line() -> void:
	show_line("", "")


func show_prompt(shown: bool) -> void:
	_prompt.visible = shown


func _set_bars(amount: float) -> void:
	_bars = amount
	_top.anchor_bottom = BAR_FRACTION * amount
	_bottom.anchor_top = 1.0 - BAR_FRACTION * amount


func _kill_tween() -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = null
