class_name TerminalScreen
extends Control
## The page drawn inside a terminal's SubViewport: a header, the body text
## typed out a few characters at a time, and a footer hint. Pure 2D, no
## knowledge of the 3D prop around it (see Terminal, which owns this and
## feeds it scroll input while the player is at the terminal).

const PHOSPHOR := Color(0.36, 1.0, 0.5)
const DIM := Color(0.2, 0.62, 0.3)
## Characters typed per second.
const TYPE_RATE := 900.0
const SCROLL_STEP := 40.0

var _font := SystemFont.new()
var _header: Label
var _body: RichTextLabel
var _footer: Label
var _typing := false


func _ready() -> void:
	_font.font_names = PackedStringArray(["Consolas", "Lucida Console", "Courier New", "Monospace"])
	_font.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var back := ColorRect.new()
	back.color = Color(0.01, 0.03, 0.015)
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(back)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 34
	box.offset_right = -34
	box.offset_top = 28
	box.offset_bottom = -24
	box.add_theme_constant_override("separation", 8)
	add_child(box)
	_header = _label(DIM)
	box.add_child(_header)
	box.add_child(_rule())
	_body = RichTextLabel.new()
	_body.bbcode_enabled = true
	_body.scroll_active = true
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_theme_font_override("normal_font", _font)
	_body.add_theme_font_override("bold_font", _font)
	_body.add_theme_font_size_override("normal_font_size", 18)
	_body.add_theme_font_size_override("bold_font_size", 18)
	_body.add_theme_color_override("default_color", PHOSPHOR)
	_body.add_theme_constant_override("line_separation", 3)
	# The page scrolls by key and wheel, not a visible bar.
	_body.get_v_scroll_bar().modulate.a = 0.0
	box.add_child(_body)
	box.add_child(_rule())
	_footer = _label(DIM)
	_footer.text = "[ESC] LOG OFF    [WHEEL / UP / DOWN] SCROLL"
	box.add_child(_footer)


## Clears the page and starts typing text (BBCode) under header.
func show_page(header: String, text: String) -> void:
	_header.text = header
	_body.text = text
	_body.visible_characters = 0
	_body.get_v_scroll_bar().value = 0.0
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
	bar.value = clampf(bar.value + lines * SCROLL_STEP, 0.0, bar.max_value)


func _process(delta: float) -> void:
	if not _typing:
		return
	var total := _body.get_total_character_count()
	var shown := _body.visible_characters + maxi(1, int(TYPE_RATE * delta))
	if shown >= total:
		finish_typing()
	else:
		_body.visible_characters = shown


func _label(color: Color) -> Label:
	var label := Label.new()
	label.add_theme_font_override("font", _font)
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", color)
	return label


func _rule() -> ColorRect:
	var line := ColorRect.new()
	line.color = DIM
	line.custom_minimum_size = Vector2(0, 2)
	return line
