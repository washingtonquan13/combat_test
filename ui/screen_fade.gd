extends CanvasLayer
## Autoload scene. Register as "ScreenFade" under Project > Project
## Settings > AutoLoad (it is ui/screen_fade.tscn, so its look is edited
## there).
##
## The black the screen goes to between areas: WorldManager.travel_area()
## covers, loads behind it, then uncovers. This file only draws it and
## never decides when. On its own CanvasLayer above MainRoot's UI and the
## cinematic bars, so nothing shows through.
##
## While anything of it is showing, it swallows the mouse: a click landing
## in the old world mid-fade would command units that are about to be gone.

@onready var _black: ColorRect = $Black

var _tween: Tween


## Goes to black over `seconds`. The returned tween is the fade itself, to
## await or not.
func cover(seconds: float) -> Tween:
	_black.mouse_filter = Control.MOUSE_FILTER_STOP
	return _fade_to(1.0, seconds)


## Back from black over `seconds`; input reaches the game again once it is
## fully gone.
func uncover(seconds: float) -> Tween:
	var tween := _fade_to(0.0, seconds)
	tween.finished.connect(func() -> void: _black.mouse_filter = Control.MOUSE_FILTER_IGNORE)
	return tween


func is_covered() -> bool:
	return _black.modulate.a > 0.0


func _fade_to(alpha: float, seconds: float) -> Tween:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_black, "modulate:a", alpha, maxf(seconds, 0.001))
	return _tween
