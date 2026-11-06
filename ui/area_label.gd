extends Control
## The SMT-style "where am I" on the overworld: the district's name small
## in the top-left corner the whole time, and big across the top for a
## moment when the avatar walks into a new one.
##
## The overworld decides which district the avatar is in (see
## overworld.gd and overworld_district.gd) and calls show_area() through
## the "area_label" group; this file only draws it. Authored in
## MainRoot.tscn like InteractPrompt, so its look is edited there.

## Seconds the banner stays fully shown, and takes to fade in or out.
@export var banner_hold: float = 2.5
@export var banner_fade: float = 0.4

@onready var _corner: Label = $Corner
@onready var _banner: Control = $Banner
@onready var _banner_label: Label = $Banner/Label

var _tween: Tween


func _ready() -> void:
	add_to_group(&"area_label")
	_clear()
	# A name belongs to the world on screen: leaving it, or switching to a
	# group somewhere else, clears it, and the overworld puts it back.
	WorldManager.world_loading.connect(func(_scene: PackedScene) -> void: _clear())
	WorldManager.world_focused.connect(func(_world: Node) -> void: _clear())
	GameMode.mode_changed.connect(func(_mode: GameMode.Mode) -> void: _refresh())


## announce: also show the banner, for walking into a new district rather
## than arriving on the overworld or coming back to it.
func show_area(display_name: String, announce: bool) -> void:
	_corner.text = display_name
	# Its plate is the label's own stylebox, so shrink it back to the new
	# name; a Label grows to fit its text but never shrinks on its own.
	_corner.reset_size()
	_refresh()
	if not announce:
		return
	_banner_label.text = display_name
	if _tween:
		_tween.kill()
	_banner.modulate.a = 0.0
	_banner.visible = true
	_tween = create_tween()
	_tween.tween_property(_banner, "modulate:a", 1.0, banner_fade)
	_tween.tween_interval(banner_hold)
	_tween.tween_property(_banner, "modulate:a", 0.0, banner_fade)
	_tween.tween_callback(_banner.hide)


func _clear() -> void:
	if _tween:
		_tween.kill()
	_corner.text = ""
	_banner.visible = false
	_refresh()


func _refresh() -> void:
	visible = _corner.text != "" and GameMode.current_mode() == GameMode.Mode.OVERWORLD
