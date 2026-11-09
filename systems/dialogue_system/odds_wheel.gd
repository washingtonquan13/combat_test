extends Control
## A wheel of fortune with one wedge per 3d6 total, coloured by what that
## total would do against a target number, so a check shows its odds at a
## glance before anything is rolled.
##
## The drawing is deliberately not exact. Wedge size goes with the square
## root of how many of the 216 rolls make that total: true proportions would
## leave a 3 or an 18 a sliver under 2 degrees, and this keeps them readable
## while 10 still clearly dwarfs 3. It only ever shows a roll SuccessRoll
## already made; the wedge sizes have no say in the result.
##
## Everything is drawn here, wheel, hub and needle, from `spin` and `dim`,
## so a skip or a tween just sets them and the picture follows. `spin` 0
## would put the 10|11 seam under the needle; totals ascend clockwise from
## the bottom, where 3 and 18 meet.

const FIRST_TOTAL: int = 3
## How many of the 216 rolls of 3d6 make each total, from FIRST_TOTAL up.
const ROLL_COUNTS: Array[int] = [1, 3, 6, 10, 15, 21, 25, 27, 27, 25, 21, 15, 10, 6, 3, 1]

const RADIUS: float = 200.0
const HUB_RADIUS: float = 52.0
const RIM_WIDTH: float = 9.0
## Where each wedge's number is centred, from the wheel's centre.
const NUMBER_RADIUS: float = 164.0
const BACKING_MARGIN: float = 6.0
## Above the rim, room for the needle's head.
const TOP_MARGIN: float = 24.0
const ARC_STEP: float = deg_to_rad(3.0)

## The needle hangs from a pivot above the rim. A wedge's edge catches it as
## it comes round, bending it up to NEEDLE_FLEX over the last PEG_REACH
## radians before the edge passes; it flicks back as the edge clears.
const NEEDLE_PIVOT_ABOVE_RIM: float = 10.0
## Short enough that the tip stops above the number it points at.
const NEEDLE_LENGTH: float = 32.0
const NEEDLE_HALF_WIDTH: float = 11.0
const NEEDLE_FLEX: float = deg_to_rad(22.0)
const PEG_REACH: float = 0.1

## How far a wedge that didn't come up fades once the wheel has landed.
const DIM_STRENGTH: float = 0.68

enum Kind {SUCCESS, FAILURE, CRITICAL_SUCCESS, CRITICAL_FAILURE}

## Per Kind, the two shades neighbouring wedges alternate between.
const FILLS: Array = [
	[Color("#2b7cc0"), Color("#1f5f98")],
	[Color("#b5364f"), Color("#8c2a40")],
	[Color("#ffd03a"), Color("#e3b42c")],
	[Color("#4d1120"), Color("#3a0c18")],
]
## Per Kind, text in that outcome's colour on a dark ground.
const INKS: Array = [Color("#62aee8"), Color("#e2566f"), Color("#ffd03a"), Color("#ff4438")]
const NUMBER_INK: Color = Color.WHITE
## On a gold wedge, where white wouldn't read.
const NUMBER_INK_ON_GOLD: Color = Color("#1c1503")
const LINE: Color = Color("#10131b")
const BACKING: Color = Color("#0a0c12")
const HUB_FILL: Color = Color("#10131b")
const HUB_RING: Color = Color("#f2c14a")
const HUB_FONT_SIZE: int = 40
const NEEDLE_FILL: Color = Color("#f4f1e6")
const HIGHLIGHT: Color = Color("#fff4cf")

## The wheel's rotation, radians, clockwise. Tweened through a roll.
var spin: float = 0.0:
	set(value):
		spin = value
		queue_redraw()
## 0 for a live wheel, 1 once landed: the wedge that came up stands out.
var dim: float = 0.0:
	set(value):
		dim = value
		queue_redraw()

## Per total, from FIRST_TOTAL: the wedge's start clockwise from the bottom
## and its size, radians.
var _starts := PackedFloat64Array()
var _spans := PackedFloat64Array()
## Per total: one wedge's outline around the wheel's centre, built once.
var _outlines: Array[PackedVector2Array] = []
var _kinds: Array[int] = []
## The total the wheel came to rest on, or 0 before it has.
var _landed: int = 0


func _init() -> void:
	custom_minimum_size = Vector2(2.0 * (RADIUS + BACKING_MARGIN), TOP_MARGIN + 2.0 * RADIUS + BACKING_MARGIN)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var weight: float = 0.0
	for count in ROLL_COUNTS:
		weight += sqrt(float(count))
	var start: float = 0.0
	for count in ROLL_COUNTS:
		var span: float = sqrt(float(count)) / weight * TAU
		_starts.append(start)
		_spans.append(span)
		_outlines.append(_wedge_outline(PI * 0.5 + start, span))
		start += span


## Shows the odds against `target` and goes back to a wheel at rest, needle
## on the middle of 10.
func show_odds(target: int) -> void:
	_landed = 0
	_kinds.clear()
	for i in ROLL_COUNTS.size():
		_kinds.append(_kind_of(FIRST_TOTAL + i, target))
	dim = 0.0
	spin = _spin_with_needle_at(10, 0.5)


## The `spin` to tween to: at least `turns` full clockwise turns from here,
## ending with the needle `fraction` of the way across `total`'s wedge.
func spin_to_land_on(total: int, fraction: float, turns: int) -> float:
	return spin + fposmod(_spin_with_needle_at(total, fraction) - spin, TAU) + turns * TAU


## Marks `total` as what came up: the hub, blank until now, shows it.
func land_on(total: int) -> void:
	_landed = total
	queue_redraw()


## `total`'s outcome colour, for text on a dark ground.
func ink_of(total: int) -> Color:
	return INKS[_kinds[_index(total)]]


func _draw() -> void:
	var centre := Vector2(size.x * 0.5, TOP_MARGIN + RADIUS)
	draw_circle(centre, RADIUS + BACKING_MARGIN, BACKING, true, -1.0, true)
	draw_set_transform(centre, spin)
	for i in ROLL_COUNTS.size():
		draw_colored_polygon(_outlines[i], _fill_of(i))
	# Thin dark lines over the polygons' hard edges, which have no
	# antialiasing of their own.
	for i in ROLL_COUNTS.size():
		_draw_rim(i)
	draw_arc(Vector2.ZERO, RADIUS - RIM_WIDTH, 0.0, TAU, 128, LINE, 1.5, true)
	for i in ROLL_COUNTS.size():
		var edge: Vector2 = Vector2.from_angle(PI * 0.5 + _starts[i])
		draw_line(edge * HUB_RADIUS, edge * (RADIUS - RIM_WIDTH), LINE, 1.25, true)
	if _landed != 0 and dim > 0.0:
		_draw_highlight(_index(_landed))
	for i in ROLL_COUNTS.size():
		_draw_number(i, centre)
	draw_set_transform(Vector2.ZERO)
	_draw_hub(centre)
	_draw_needle(centre)


func _draw_rim(i: int) -> void:
	var from: float = PI * 0.5 + _starts[i]
	var colour: Color = FILLS[_kinds[i]][0]
	var steps: int = maxi(2, ceili(_spans[i] / ARC_STEP))
	draw_arc(Vector2.ZERO, RADIUS - RIM_WIDTH * 0.5, from, from + _spans[i], steps, _faded(colour, i), RIM_WIDTH, true)


func _draw_highlight(i: int) -> void:
	var outline: PackedVector2Array = _outlines[i].duplicate()
	outline.append(outline[0])
	draw_polyline(outline, Color(HIGHLIGHT, dim), 3.0, true)


func _draw_number(i: int, centre: Vector2) -> void:
	var mid: float = PI * 0.5 + _starts[i] + _spans[i] * 0.5
	var font: Font = get_theme_font(&"font", &"Label")
	var font_size: int = clampi(int(NUMBER_RADIUS * _spans[i] * 0.55), 13, 26)
	var text: String = str(FIRST_TOTAL + i)
	var width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var baseline: float = (font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5
	var ink: Color = NUMBER_INK_ON_GOLD if _kinds[i] == Kind.CRITICAL_SUCCESS else NUMBER_INK
	if not _is_landed(i):
		ink.a = 1.0 - DIM_STRENGTH * dim
	# Upright when the wedge is under the needle.
	var at: Vector2 = centre + (Vector2.from_angle(mid) * NUMBER_RADIUS).rotated(spin)
	draw_set_transform(at, mid + PI * 0.5 + spin)
	draw_string(font, Vector2(-width * 0.5, baseline), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, ink)


func _draw_hub(centre: Vector2) -> void:
	draw_circle(centre, HUB_RADIUS, HUB_FILL, true, -1.0, true)
	draw_arc(centre, HUB_RADIUS, 0.0, TAU, 64, HUB_RING, 3.0, true)
	if _landed == 0:
		return
	var text: String = str(_landed)
	var font: Font = get_theme_font(&"font", &"Label")
	var width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, HUB_FONT_SIZE).x
	var baseline: float = (font.get_ascent(HUB_FONT_SIZE) - font.get_descent(HUB_FONT_SIZE)) * 0.5
	draw_string(font, centre + Vector2(-width * 0.5, baseline), text, HORIZONTAL_ALIGNMENT_LEFT, -1, HUB_FONT_SIZE, ink_of(_landed))


func _draw_needle(centre: Vector2) -> void:
	var pivot: Vector2 = centre + Vector2(0.0, -RADIUS - NEEDLE_PIVOT_ABOVE_RIM)
	draw_set_transform(pivot, _needle_bend())
	var shape := PackedVector2Array([
		Vector2(-NEEDLE_HALF_WIDTH, -6.0),
		Vector2(NEEDLE_HALF_WIDTH, -6.0),
		Vector2(0.0, NEEDLE_LENGTH),
	])
	draw_colored_polygon(shape, NEEDLE_FILL)
	var outline: PackedVector2Array = shape.duplicate()
	outline.append(shape[0])
	draw_polyline(outline, LINE, 2.0, true)
	draw_circle(Vector2.ZERO, 3.5, LINE, true, -1.0, true)
	draw_set_transform(Vector2.ZERO)


## Clockwise, so the wedge edge coming up on the needle is the lower edge of
## the wedge under it, and it pushes the tip the way the wheel is going.
## From `spin` alone, so it can't drift from the wheel or depend on the
## frame rate.
func _needle_bend() -> float:
	var i: int = _index_under_needle()
	var from_edge: float = _needle_position() - _starts[i]
	var reach: float = minf(PEG_REACH, _spans[i] * 0.5)
	if from_edge >= reach:
		return 0.0
	return -NEEDLE_FLEX * (1.0 - from_edge / reach)


func _needle_position() -> float:
	return fposmod(PI - spin, TAU)


func _index_under_needle() -> int:
	return clampi(_starts.bsearch(_needle_position(), false) - 1, 0, ROLL_COUNTS.size() - 1)


func _spin_with_needle_at(total: int, fraction: float) -> float:
	var i: int = _index(total)
	return PI - _starts[i] - fraction * _spans[i]


func _fill_of(i: int) -> Color:
	return _faded(FILLS[_kinds[i]][(FIRST_TOTAL + i) % 2], i)


func _faded(colour: Color, i: int) -> Color:
	if _is_landed(i):
		return colour
	return colour.lerp(BACKING, DIM_STRENGTH * dim)


func _is_landed(i: int) -> bool:
	return _landed == FIRST_TOTAL + i


func _index(total: int) -> int:
	return clampi(total - FIRST_TOTAL, 0, ROLL_COUNTS.size() - 1)


## Annular, hub to rim, in the wheel's own frame.
static func _wedge_outline(from: float, span: float) -> PackedVector2Array:
	var steps: int = maxi(2, ceili(span / ARC_STEP))
	var outline := PackedVector2Array()
	for s in steps + 1:
		outline.append(Vector2.from_angle(from + span * s / steps) * RADIUS)
	for s in range(steps, -1, -1):
		outline.append(Vector2.from_angle(from + span * s / steps) * HUB_RADIUS)
	return outline


static func _kind_of(total: int, target: int) -> Kind:
	var outcome: Dictionary = SuccessRoll.outcome_of(total, target)
	if outcome.critical_success:
		return Kind.CRITICAL_SUCCESS
	if outcome.critical_failure:
		return Kind.CRITICAL_FAILURE
	return Kind.SUCCESS if outcome.success else Kind.FAILURE
