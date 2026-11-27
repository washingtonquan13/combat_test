class_name TerminalScreen
extends Control
## The page drawn inside a terminal's SubViewport: a header, the body text
## typed out a few characters at a time, and a footer hint. Pure 2D, no
## knowledge of the 3D prop around it (see Terminal, which owns this and
## feeds it scroll input while the player is at the terminal).
##
## The layout is designed on a 640x480 grid and scaled to whatever size the
## SubViewport is, so raising its resolution only makes the page sharper.
## crt_screen.gdshader measures its scanlines on the same grid.

const PHOSPHOR := Color(0.36, 1.0, 0.5)
const DIM := Color(0.2, 0.62, 0.3)
## Rows of the design grid (crt_screen.gdshader's design_lines).
const DESIGN_HEIGHT := 480.0
## Characters typed per second.
const TYPE_RATE := 900.0
## Lines moved by one scroll step.
const SCROLL_LINES := 2
## Text size and the gap between lines, on the design grid.
const FONT_SIZE := 18.0
const LINE_GAP := 3.0

## The two bundled faces (OFL, licences beside them). DotGothic16 is the
## default and has kana and kanji; VT323 is Latin only and falls back to
## DotGothic16 for anything it lacks.
const DOT_GOTHIC: FontFile = preload("res://assets/fonts/dotgothic16/DotGothic16-Regular.ttf")
const VT323: FontFile = preload("res://assets/fonts/vt323/VT323-Regular.ttf")
enum Face { DOT_GOTHIC, VT323 }
## How quickly the view catches up with a scroll (1/s). Gliding rather than
## jumping is what gives the shader's phosphor trail something to trail.
const SCROLL_CATCH_UP := 18.0

## How fast the page is scrolling, in page heights per second (+ is the text
## moving up). Terminal hands it to the glass for the afterglow.
var scroll_velocity := 0.0

var _font: Font = DOT_GOTHIC
var _scale := 1.0
var _header: Label
var _body: RichTextLabel
var _body_frame: Control
var _footer: Label
var _typing := false
var _scroll_to := 0.0
var _scroll_at := 0.0


## The face at size (pixels). VT323's fallback is DotGothic16 trimmed to
## VT323's ascent and descent at that size: untrimmed, its taller line box
## made every line with a kana on it taller than the rest (and Font's height
## is the tallest in the fallback chain), so the page was off its line grid.
static func make_font(face: Face, size: int) -> Font:
	if face == Face.VT323:
		var fallback := FontVariation.new()
		fallback.base_font = DOT_GOTHIC
		fallback.spacing_top = roundi(VT323.get_ascent(size) - DOT_GOTHIC.get_ascent(size))
		fallback.spacing_bottom = roundi(VT323.get_descent(size) - DOT_GOTHIC.get_descent(size))
		var font := FontVariation.new()
		font.base_font = VT323
		font.fallbacks = [fallback]
		return font
	return DOT_GOTHIC


## Swaps the page's face (Terminal calls this from its own _ready, after
## this one has built the page).
func set_face(face: Face) -> void:
	_font = make_font(face, _px(FONT_SIZE))
	for label: Label in [_header, _footer]:
		label.add_theme_font_override("font", _font)
	_body.add_theme_font_override("normal_font", _font)
	_body.add_theme_font_override("bold_font", _font)
	_fit_body_to_lines()


## One line of body text, in this viewport's pixels.
func line_height() -> float:
	return _font.get_height(_px(FONT_SIZE)) + _px(LINE_GAP)


func _ready() -> void:
	_scale = get_viewport_rect().size.y / DESIGN_HEIGHT
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var back := ColorRect.new()
	back.color = Color(0.01, 0.03, 0.015)
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(back)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = _px(34)
	box.offset_right = -_px(34)
	box.offset_top = _px(28)
	box.offset_bottom = -_px(24)
	box.add_theme_constant_override("separation", _px(8))
	add_child(box)
	_header = _label(DIM)
	box.add_child(_header)
	box.add_child(_rule())
	# The body sits in a frame that takes the spare height, and is itself cut
	# to a whole number of lines (_fit_body_to_lines), so the bottom row is
	# never a sliver of a line.
	_body_frame = Control.new()
	_body_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body_frame.resized.connect(_fit_body_to_lines)
	box.add_child(_body_frame)
	_body = RichTextLabel.new()
	_body.bbcode_enabled = true
	_body.scroll_active = true
	_body.add_theme_font_override("normal_font", _font)
	_body.add_theme_font_override("bold_font", _font)
	_body.add_theme_font_size_override("normal_font_size", _px(FONT_SIZE))
	_body.add_theme_font_size_override("bold_font_size", _px(FONT_SIZE))
	_body.add_theme_color_override("default_color", PHOSPHOR)
	_body.add_theme_constant_override("line_separation", _px(LINE_GAP))
	# The page scrolls by key and wheel, not a visible bar.
	_body.get_v_scroll_bar().modulate.a = 0.0
	_body_frame.add_child(_body)
	box.add_child(_rule())
	_footer = _label(DIM)
	_footer.text = "[ESC] LOG OFF    [WHEEL / UP / DOWN] SCROLL"
	box.add_child(_footer)


func _fit_body_to_lines() -> void:
	var line := line_height()
	var rows := maxf(1.0, floorf(_body_frame.size.y / line))
	_body.position = Vector2.ZERO
	_body.size = Vector2(_body_frame.size.x, rows * line)


## The part of the page that scrolls, as (x0, y0, x1, y1) fractions of the
## page, for the glass's afterglow.
func scroll_area() -> Vector4:
	var r := _body.get_global_rect()
	var page := get_viewport_rect().size
	return Vector4(r.position.x / page.x, r.position.y / page.y, r.end.x / page.x, r.end.y / page.y)


## Clears the page and starts typing text (BBCode) under header.
func show_page(header: String, text: String) -> void:
	_header.text = header
	_body.text = text
	_body.visible_characters = 0
	_body.get_v_scroll_bar().value = 0.0
	_scroll_to = 0.0
	_scroll_at = 0.0
	scroll_velocity = 0.0
	_typing = true


## Shows the whole page at once (a click or key while it is still typing).
func finish_typing() -> bool:
	if not _typing:
		return false
	_typing = false
	_body.visible_characters = -1
	return true


func scroll(lines: float) -> void:
	finish_typing()
	var bar := _body.get_v_scroll_bar()
	_scroll_to = clampf(_scroll_to + lines * SCROLL_LINES * line_height(), 0.0, maxf(0.0, bar.max_value - bar.page))


func _process(delta: float) -> void:
	_follow_scroll(delta)
	if not _typing:
		return
	var total := _body.get_total_character_count()
	var shown := _body.visible_characters + maxi(1, int(TYPE_RATE * delta))
	if shown >= total:
		finish_typing()
	else:
		_body.visible_characters = shown


## Eases the view toward _scroll_to. The position is kept here, not read
## back from the bar: the bar rounds to whole pixels, and easing from its
## rounded value stalled a few pixels short of the target.
func _follow_scroll(delta: float) -> void:
	var was := _scroll_at
	if absf(_scroll_to - _scroll_at) < 0.5:
		_scroll_at = _scroll_to
	else:
		_scroll_at = lerpf(_scroll_at, _scroll_to, 1.0 - exp(-SCROLL_CATCH_UP * delta))
	_body.get_v_scroll_bar().value = _scroll_at
	scroll_velocity = (_scroll_at - was) / size.y / delta if delta > 0.0 else 0.0


func _label(color: Color) -> Label:
	var label := Label.new()
	label.add_theme_font_override("font", _font)
	label.add_theme_font_size_override("font_size", _px(FONT_SIZE))
	label.add_theme_color_override("font_color", color)
	return label


func _rule() -> ColorRect:
	var line := ColorRect.new()
	line.color = DIM
	line.custom_minimum_size = Vector2(0, _px(2))
	return line


## A length on the 640x480 design grid, in this viewport's pixels.
func _px(design: float) -> int:
	return roundi(design * _scale)
