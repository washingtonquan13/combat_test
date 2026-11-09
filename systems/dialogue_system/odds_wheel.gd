extends Control
## A wheel of fortune with one wedge per 3d6 total, showing what that total
## would do against a target number, so a check shows its odds at a glance
## before anything is rolled.
##
## The drawing is deliberately not exact. Wedge size goes with the square
## root of how many of the 216 rolls make that total: true proportions would
## leave a 3 or an 18 a sliver under 2 degrees, and this keeps them readable
## while 10 still clearly dwarfs 3. It only ever shows a roll SuccessRoll
## already made; the wedge sizes have no say in the result.
##
## The picture is layers of one Blender render (tools/wheel/build.sh), and
## follows `spin` and `dim`, so a skip or a tween just sets them. `spin` 0
## would put the 10|11 seam under the needle; totals ascend clockwise from
## the bottom, where 3 and 18 meet.

const LOOK_LACQUER: StringName = &"lacquer"
const LOOK_WOOD: StringName = &"wood"
const DEFAULT_LOOK: StringName = LOOK_LACQUER
const LOOK_FOLDER: String = "res://assets/ui/wheel/%s/"
const WheelShader: Shader = preload("res://systems/dialogue_system/odds_wheel.gdshader")

const FIRST_TOTAL: int = 3
## How many of the 216 rolls of 3d6 make each total, from FIRST_TOTAL up.
const ROLL_COUNTS: Array[int] = [1, 3, 6, 10, 15, 21, 25, 27, 27, 25, 21, 15, 10, 6, 3, 1]

## On screen, to the outside of the rim.
const RADIUS: float = 200.0
## Around the rim, and above it for the needle's head.
const SIDE_MARGIN: float = RADIUS * 0.03
const TOP_MARGIN: float = RADIUS * 0.16

## The render's own measurements, from tools/wheel/render_wheel.py: how much
## of the scene the square image spans, the rim's outer radius, the axis
## and the needle's pin as heights above the image's centre line, and the
## wedge's visible edges against the hub and the rim.
const RENDER_SPAN: float = 5.05
const RENDER_RIM: float = 2.11
const RENDER_AXIS_Y: float = -0.14
const RENDER_NEEDLE_PIN_Y: float = 2.14
const RENDER_HUB_EDGE: float = 0.6
const RENDER_RIM_EDGE: float = 1.86
const RENDER_HUB_INSIDE: float = 0.47

## The flapper is a sprung arm hanging from the pin. Pegs shove its tip along
## as they pass; when one slips off the tip the spring snaps the arm back, and
## it clacks into the next peg or rings out. Sizes are in render units. The
## reach is how far down the arm a peg can catch it, which is less than the
## arm's drawn length: the arm rides above the pegs and only its underside
## catches them, and a full-length catch would swing it nearly 50 degrees.
const FLAPPER_PIN_HEIGHT: float = RENDER_NEEDLE_PIN_Y - RENDER_AXIS_Y
const FLAPPER_REACH: float = 0.3
const PEG_RING: float = 1.96
const PEG_RADIUS: float = 0.06
## The spring and damper, per radian of swing: rings at about 4.5 Hz.
const FLAPPER_STIFFNESS: float = 800.0
const FLAPPER_DAMPING: float = 10.0
## Speed kept after clacking into a peg or the stop.
const FLAPPER_BOUNCE: float = 0.35
## Where the arm stops swinging, and the fastest a peg can fling it.
const FLAPPER_STOP: float = deg_to_rad(30.0)
const FLAPPER_MAX_SPEED: float = 16.0
## Small enough that a peg at the wheel's top speed can't jump the catch.
const FLAPPER_STEPS_PER_SECOND: float = 960.0
const FLAPPER_AT_REST: float = 0.0005
## How far short of the needle a peg still leaves it alone at rest, and how
## far past the needle one has to get before it has let go, as wheel angles.
const PEG_TOUCHES_AT: float = asin(PEG_RADIUS / PEG_RING)
const PEG_LETS_GO_AT: float = acos(
		(PEG_RING * PEG_RING + FLAPPER_PIN_HEIGHT * FLAPPER_PIN_HEIGHT
		- (FLAPPER_REACH + PEG_RADIUS) * (FLAPPER_REACH + PEG_RADIUS))
		/ (2.0 * PEG_RING * FLAPPER_PIN_HEIGHT))
const LANDING_CLEARANCE: float = 0.003

## The share of a frame the blur covers, and the most it can smear.
const SHUTTER: float = 0.5
const MAX_BLUR: float = 0.35

## How far a wedge that didn't come up fades once the wheel has landed.
const DIM_STRENGTH: float = 0.68
const HIGHLIGHT_WIDTH: float = 4.0

enum Kind {SUCCESS, FAILURE, CRITICAL_SUCCESS, CRITICAL_FAILURE}

## The slice of the renders with the pegs, after one slice per Kind.
const PEGS_SLICE: int = 4

## Per Kind, text in that outcome's colour on a dark ground.
const INKS: Array = [Color("#62aee8"), Color("#e2566f"), Color("#ffd03a"), Color("#ff4438")]
const BACKING: Color = Color("#0a0c12")
const HIGHLIGHT: Color = Color("#fff4cf")
const HUB_FONT_SIZE: int = int(RADIUS * 0.2)

## The wheel's rotation, radians, clockwise. Tweened through a roll.
var spin: float = 0.0:
	set(value):
		var moved: float = absf(value - spin)
		spin = value
		_show_spin(minf(moved * SHUTTER, MAX_BLUR))
		set_process(true)
## 0 for a live wheel, 1 once landed: the wedge that came up stands out.
var dim: float = 0.0:
	set(value):
		dim = value
		_disc_material.set_shader_parameter(&"dim", dim)
## LOOK_LACQUER or LOOK_WOOD.
var look: StringName = &"":
	set(value):
		if value != look:
			look = value
			_load_look()

## Per total, from FIRST_TOTAL: the wedge's start clockwise from the bottom
## and its size, radians.
var _starts := PackedFloat32Array()
var _spans := PackedFloat32Array()
var _kinds: Array[int] = []

var _disc_material: ShaderMaterial
var _peg_material: ShaderMaterial
var _sheen: TextureRect
var _frame: TextureRect
var _needle: TextureRect
var _hub_label: Label

## The flapper's swing, radians with the tip towards the way the wheel turns,
## its speed, and the `spin` it has been simulated up to.
var _swing: float = 0.0
var _swing_speed: float = 0.0
var _flapper_spin: float = 0.0


func _init() -> void:
	custom_minimum_size = Vector2(2.0 * (RADIUS + SIDE_MARGIN), TOP_MARGIN + 2.0 * RADIUS + SIDE_MARGIN)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var weight: float = 0.0
	for count in ROLL_COUNTS:
		weight += sqrt(float(count))
	var start: float = 0.0
	for count in ROLL_COUNTS:
		var span: float = sqrt(float(count)) / weight * TAU
		_starts.append(start)
		_spans.append(span)
		start += span
	_build_layers()
	look = DEFAULT_LOOK
	set_process(false)


## Runs the flapper up to the wheel. The wheel drives it and never the other
## way round: where the wheel stops is the dice's to say.
func _process(delta: float) -> void:
	var steps: int = maxi(1, ceili(delta * FLAPPER_STEPS_PER_SECOND))
	var from: float = _flapper_spin
	for step in steps:
		_flapper_spin = lerpf(from, spin, float(step + 1) / steps)
		_step_flapper(delta / steps)
	_flapper_spin = spin
	_needle.rotation = -_swing
	if is_equal_approx(from, spin) and absf(_swing) < FLAPPER_AT_REST \
			and absf(_swing_speed) < FLAPPER_AT_REST * FLAPPER_STIFFNESS:
		_settle_flapper()
		set_process(false)


## Shows the odds against `target` and goes back to a wheel at rest, needle
## on the middle of 10.
func show_odds(target: int) -> void:
	_hub_label.text = ""
	_disc_material.set_shader_parameter(&"landed", -1)
	_kinds.clear()
	var slices := PackedInt32Array()
	for i in ROLL_COUNTS.size():
		_kinds.append(_kind_of(FIRST_TOTAL + i, target))
		slices.append(_kinds[i])
	_disc_material.set_shader_parameter(&"kinds", slices)
	dim = 0.0
	spin = _resting_spin()
	_show_spin(0.0)
	_settle_flapper()


## The `spin` to tween to: at least `turns` full clockwise turns from here,
## ending with the needle `fraction` of the way across the part of `total`'s
## wedge where the flapper can hang free, so it comes to rest pointing at it.
func spin_to_land_on(total: int, fraction: float, turns: int) -> float:
	var span: float = _spans[_index(total)]
	var first: float = (PEG_TOUCHES_AT + LANDING_CLEARANCE) / span
	var last: float = 1.0 - (PEG_LETS_GO_AT + LANDING_CLEARANCE) / span
	var where: float = lerpf(first, last, fraction)
	return spin + fposmod(_spin_with_needle_at(total, where) - spin, TAU) + turns * TAU


## Marks `total` as what came up: the hub, blank until now, shows it.
func land_on(total: int) -> void:
	_disc_material.set_shader_parameter(&"landed", _index(total))
	_hub_label.text = str(total)
	_hub_label.add_theme_color_override(&"font_color", ink_of(total))
	_show_spin(0.0)


## `total`'s outcome colour, for text on a dark ground.
func ink_of(total: int) -> Color:
	return INKS[_kinds[_index(total)]]


func _build_layers() -> void:
	var side: float = _frame_side()
	_disc_material = _spinning_material(-1)
	_add_layer(_spinning_rect(_disc_material), side)
	_sheen = _add_layer(_picture(), side)
	var additive := CanvasItemMaterial.new()
	additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_sheen.material = additive
	_frame = _add_layer(_picture(), side)
	_peg_material = _spinning_material(PEGS_SLICE)
	_add_layer(_spinning_rect(_peg_material), side)
	_needle = _add_layer(_picture(), side)
	_needle.pivot_offset = _needle_pin() * side

	_disc_material.set_shader_parameter(&"starts", _starts)
	_disc_material.set_shader_parameter(&"spans", _spans)
	_disc_material.set_shader_parameter(&"dim_strength", DIM_STRENGTH)
	_disc_material.set_shader_parameter(&"backing", BACKING)
	_disc_material.set_shader_parameter(&"highlight", HIGHLIGHT)
	_disc_material.set_shader_parameter(&"hub_edge", RENDER_HUB_EDGE / RENDER_SPAN)
	_disc_material.set_shader_parameter(&"rim_edge", RENDER_RIM_EDGE / RENDER_SPAN)
	_disc_material.set_shader_parameter(&"highlight_width", HIGHLIGHT_WIDTH / side)

	_hub_label = Label.new()
	add_child(_hub_label)
	var hub: float = RENDER_HUB_INSIDE * _pixels_per_unit()
	_hub_label.anchor_left = 0.5
	_hub_label.anchor_right = 0.5
	_hub_label.offset_left = -hub
	_hub_label.offset_right = hub
	_hub_label.offset_top = TOP_MARGIN + RADIUS - hub
	_hub_label.offset_bottom = TOP_MARGIN + RADIUS + hub
	_hub_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hub_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hub_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hub_label.add_theme_font_size_override(&"font_size", HUB_FONT_SIZE)


## Every layer is the same square image, so they all line up on the axis.
## The square is bigger than this Control; nothing clips it.
func _add_layer(layer: Control, side: float) -> Control:
	add_child(layer)
	var left: float = -_axis().x * side
	var top: float = TOP_MARGIN + RADIUS - _axis().y * side
	layer.anchor_left = 0.5
	layer.anchor_right = 0.5
	layer.offset_left = left
	layer.offset_right = left + side
	layer.offset_top = top
	layer.offset_bottom = top + side
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return layer


func _picture() -> TextureRect:
	var picture := TextureRect.new()
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.stretch_mode = TextureRect.STRETCH_SCALE
	picture.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return picture


func _spinning_rect(spinning: ShaderMaterial) -> ColorRect:
	var rect := ColorRect.new()
	rect.material = spinning
	return rect


func _spinning_material(fixed_slice: int) -> ShaderMaterial:
	var spinning := ShaderMaterial.new()
	spinning.shader = WheelShader
	spinning.set_shader_parameter(&"pivot", _axis())
	spinning.set_shader_parameter(&"baked_spin", _resting_spin())
	spinning.set_shader_parameter(&"fixed_slice", fixed_slice)
	return spinning


func _load_look() -> void:
	var folder: String = LOOK_FOLDER % look
	var renders: TextureLayered = load(folder + "spinning.png")
	_disc_material.set_shader_parameter(&"renders", renders)
	_peg_material.set_shader_parameter(&"renders", renders)
	_sheen.texture = load(folder + "sheen.png")
	_frame.texture = load(folder + "frame.png")
	_needle.texture = load(folder + "needle.png")


func _show_spin(blur: float) -> void:
	for spinning in [_disc_material, _peg_material]:
		spinning.set_shader_parameter(&"spin", spin)
		spinning.set_shader_parameter(&"blur", blur)


## The render's axis as a fraction of the image.
func _axis() -> Vector2:
	return Vector2(0.5, 0.5 - RENDER_AXIS_Y / RENDER_SPAN)


func _needle_pin() -> Vector2:
	return Vector2(0.5, 0.5 - RENDER_NEEDLE_PIN_Y / RENDER_SPAN)


func _pixels_per_unit() -> float:
	return RADIUS / RENDER_RIM


func _frame_side() -> float:
	return RENDER_SPAN * _pixels_per_unit()


func _settle_flapper() -> void:
	_swing = 0.0
	_swing_speed = 0.0
	_flapper_spin = spin
	_needle.rotation = 0.0


func _step_flapper(dt: float) -> void:
	var before: float = _swing
	_swing_speed -= (FLAPPER_STIFFNESS * _swing + FLAPPER_DAMPING * _swing_speed) * dt
	_swing += _swing_speed * dt
	var free: float = _swing
	for start in _starts:
		_swing = maxf(_swing, _swing_a_peg_allows(wrapf(start + _flapper_spin - PI, -PI, PI)))
	if _swing > free:
		var dragged: float = (_swing - before) / dt
		_swing_speed = minf(maxf(dragged, -_swing_speed * FLAPPER_BOUNCE), FLAPPER_MAX_SPEED)
	if absf(_swing) > FLAPPER_STOP:
		_swing = signf(_swing) * FLAPPER_STOP
		if _swing * _swing_speed > 0.0:
			_swing_speed *= -FLAPPER_BOUNCE


## The least swing that keeps the arm clear of a peg `off` radians past the
## top. Only ever a lower limit: the wheel only turns one way, so pegs come at
## the arm from behind. -INF once the peg is out of the arm's reach.
func _swing_a_peg_allows(off: float) -> float:
	if absf(off) >= PEG_LETS_GO_AT:
		return -INF
	var across: float = PEG_RING * sin(off)
	var down: float = FLAPPER_PIN_HEIGHT - PEG_RING * cos(off)
	var distance: float = sqrt(across * across + down * down)
	var clearing: float
	if distance * distance - PEG_RADIUS * PEG_RADIUS <= FLAPPER_REACH * FLAPPER_REACH:
		clearing = asin(PEG_RADIUS / distance)
	else:
		clearing = acos((distance * distance + FLAPPER_REACH * FLAPPER_REACH - PEG_RADIUS * PEG_RADIUS)
				/ (2.0 * distance * FLAPPER_REACH))
	return atan2(across, down) + clearing


func _resting_spin() -> float:
	return _spin_with_needle_at(10, 0.5)


func _spin_with_needle_at(total: int, fraction: float) -> float:
	var i: int = _index(total)
	return PI - _starts[i] - fraction * _spans[i]


func _index(total: int) -> int:
	return clampi(total - FIRST_TOTAL, 0, ROLL_COUNTS.size() - 1)


static func _kind_of(total: int, target: int) -> Kind:
	var outcome: Dictionary = SuccessRoll.outcome_of(total, target)
	if outcome.critical_success:
		return Kind.CRITICAL_SUCCESS
	if outcome.critical_failure:
		return Kind.CRITICAL_FAILURE
	return Kind.SUCCESS if outcome.success else Kind.FAILURE
