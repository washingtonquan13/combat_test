class_name AlignmentGrid
extends Control
## Continuous 2-axis alignment marker — Kingmaker-style, but a plain
## square instead of a wheel. The 3x3 lines are reference only; the dot
## is plotted at the unit's exact (alignment, tendency) position rather
## than snapping to one of 9 cells. party_overview.gd owns the category
## label shown above this for the coarse Chaotic/Neutral/Lawful x
## Dark/Neutral/Light read — the dot's job is showing how far into that
## band the unit actually sits.

## Raw alignment/tendency are unbounded running totals (see unit.gd), but
## the dot needs a fixed range to plot against. 100 is 10 shifts deep in
## one direction (UnitAlignment.ALIGNMENT_SHIFT_AMOUNT=10) — well past
## the neutral band (UnitAlignment.ALIGNMENT_NEUTRAL_THRESHOLD=25), so
## the dot has room to move within a band before pinning to the edge.
## Tune freely.
const DISPLAY_RANGE: float = 100.0
const DOT_RADIUS: float = 7.0
const EDGE_LABEL_SIZE: int = 12
const EDGE_LABEL_MARGIN: float = 6.0
const LINE_COLOR: Color = Color(1, 1, 1, 0.25)
const EDGE_LABEL_COLOR: Color = Color(1, 1, 1, 0.45)
const DOT_FILL_COLOR: Color = Color(0.949, 0.807, 0.396)
const DOT_OUTLINE_COLOR: Color = Color(0, 0, 0, 0.6)

var _fraction: Vector2 = Vector2(0.5, 0.5)


func set_alignment(alignment: int, tendency: int) -> void:
	var x: float = clampf((alignment + DISPLAY_RANGE) / (DISPLAY_RANGE * 2.0), 0.0, 1.0)
	var y: float = clampf(1.0 - (tendency + DISPLAY_RANGE) / (DISPLAY_RANGE * 2.0), 0.0, 1.0)
	_fraction = Vector2(x, y)
	queue_redraw()


func _draw() -> void:
	var box: Vector2 = size
	draw_rect(Rect2(Vector2.ZERO, box), LINE_COLOR, false, 2.0)
	draw_line(Vector2(box.x / 3.0, 0), Vector2(box.x / 3.0, box.y), LINE_COLOR, 1.0)
	draw_line(Vector2(box.x * 2.0 / 3.0, 0), Vector2(box.x * 2.0 / 3.0, box.y), LINE_COLOR, 1.0)
	draw_line(Vector2(0, box.y / 3.0), Vector2(box.x, box.y / 3.0), LINE_COLOR, 1.0)
	draw_line(Vector2(0, box.y * 2.0 / 3.0), Vector2(box.x, box.y * 2.0 / 3.0), LINE_COLOR, 1.0)

	var font: Font = get_theme_default_font()
	_draw_edge_label(font, "Light", Vector2(box.x / 2.0, EDGE_LABEL_MARGIN + EDGE_LABEL_SIZE), true)
	_draw_edge_label(font, "Dark", Vector2(box.x / 2.0, box.y - EDGE_LABEL_MARGIN), true)
	_draw_edge_label(font, "Chaos", Vector2(EDGE_LABEL_MARGIN, box.y / 2.0 + EDGE_LABEL_SIZE / 3.0), false)
	_draw_edge_label(font, "Law", Vector2(box.x - EDGE_LABEL_MARGIN, box.y / 2.0 + EDGE_LABEL_SIZE / 3.0), false, true)

	var dot_pos: Vector2 = Vector2(_fraction.x * box.x, _fraction.y * box.y)
	draw_circle(dot_pos, DOT_RADIUS, DOT_FILL_COLOR)
	draw_circle(dot_pos, DOT_RADIUS, DOT_OUTLINE_COLOR, false, 1.5)


func _draw_edge_label(font: Font, text: String, anchor: Vector2, center_horizontal: bool, align_right: bool = false) -> void:
	var text_width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, EDGE_LABEL_SIZE).x
	var pos: Vector2 = anchor
	if center_horizontal:
		pos.x -= text_width / 2.0
	elif align_right:
		pos.x -= text_width
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, EDGE_LABEL_SIZE, EDGE_LABEL_COLOR)
