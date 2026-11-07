extends Control
## Shows a 3d6 throw for a dialogue skill check, landing on the exact
## faces SuccessRoll.roll_vs() already rolled — a check asks for it with
## Conversation.show(&"dice", {skill, roll}), which parks the choice until
## this calls Conversation.complete(). The roll is fully decided before
## this ever runs; this only plays back an already-final result.
##
## BG3-style sprite dice, no 3D in game. tools/dice/d6_throws.py simulates
## a few real throws; tools/dice/render_d6_sheets.py renders each throw six
## times, once per face it can end on, as one continuous roll from launch
## to rest (the motion is the same, only which face is which differs). The
## result is known before anything plays, so a die simply plays the roll
## that ends on its face: no cut anywhere. The sheets live in
## assets/ui/dice/ beside d6_dice.json, the sidecar that carries every
## count, rate and each throw's path; nothing here hardcodes them. Each die
## is a 1:1 sprite (the sprites only spin, the travel is ours), with a
## UI-drawn shadow that drifts and softens with height.
##
## A d6 doesn't roam like a d20: it hits the table, bounces, tips over a
## few edges and stops. So only the throw-in is ours: every roll gives each
## die a fresh flight in, a straight line (a die in the air keeps its
## course) from somewhere below its slot to where its throw first touches
## down, heading roughly the way the throw does and at least as fast. From
## that touchdown on, the die follows its throw's own path, the one its
## spin was simulated with, so every bounce and tip moves it the way it
## turns. The height, and so the shadow, is always the throw's own. Routes
## are redrawn until no two dice ever come close, so they never overlap.
##
## Layout, top to bottom: the tray (the dice rest in a row across its
## middle), the verdict row (target plate left, total plate right), the
## verdict line, the button. The card sits centred above the dialogue band.
##
## Flow: idle shows the target plate and a Roll button. Roll throws three
## different throws into the three slots in random order, staggered; each
## die, as it lands, becomes its still (blank face + a separate numeral
## layer, so a critical can tint the numeral), glints once, and adds to the
## running total. Then the total slams sideways into the target and the
## verdict shows. A click on the card skips to that end state; Continue
## completes the wait.
##
## Hidden by default. MainRoot.tscn adds exactly one of these as a
## CanvasLayer child, after DialogueOverlay/ConversationLog so it
## renders on top of both while a roll is in progress.

const DICE_DIR: String = "res://assets/ui/dice/"
const SIDECAR_PATH: String = DICE_DIR + "d6_dice.json"
const STILL_BLANK_SHEET: String = "d6_still_blank.png"
## One row, faces 1..6 left to right.
const NUMERALS_SHEET: String = "d6_numerals.png"
const GLINT_SHEET: String = "d6_glint.png"
const SLOTS: int = 3

## Each die fades in over its first frames, counted in sheet frames.
const FADE_IN_FRAMES: float = 2.0
## The total plate pops each time a die adds to it.
const POP_SCALE: float = 1.15
const POP_TIME: float = 0.2
## After the last glint: a beat, then the total slams across into the
## target beside it.
const VERDICT_DELAY: float = 0.25
const SLAM_TIME: float = 0.13
const SLAM_SCALE: float = 1.3
const SLAM_HOLD: float = 0.12
const SLAM_RETURN_TIME: float = 0.35
## Gap left between the slammed total and the target plate it hits, px.
const SLAM_GAP: float = 4.0
## The blank stills shown in the slots while waiting on Roll.
const IDLE_GHOST_ALPHA: float = 0.3

## The shadow is a soft ellipse on the panel under each die. At rest it
## sits SHADOW_REST_OFFSET from the die's centre, wide enough that a dark
## rim shows round the face, most below-right; per px of height it drifts
## by SHADOW_OFFSET_PER_Z, grows, and fades (never below SHADOW_MIN_FADE of
## its rest strength). Black on a near-black card cannot read, so CARD_BG
## is lifted enough to leave it something to darken.
const SHADOW_SIZE: Vector2 = Vector2(136.0, 122.0)
const SHADOW_REST_OFFSET: Vector2 = Vector2(6.0, 12.0)
const SHADOW_OFFSET_PER_Z: Vector2 = Vector2(0.3, 0.45)
const SHADOW_GROW_PER_Z: float = 0.004
const SHADOW_FADE_PER_Z: float = 0.005
const SHADOW_MIN_FADE: float = 0.35
const SHADOW_ALPHA: float = 0.9

const GOLD: Color = Color(0.95, 0.78, 0.33)
const RED: Color = Color(0.9, 0.28, 0.24)
const CRIT_SUCCESS_TINT: Color = Color(1.0, 0.82, 0.3)
const CRIT_FAILURE_TINT: Color = Color(1.0, 0.32, 0.27)
const CARD_BG: Color = Color(0.085, 0.08, 0.074, 0.9)
const PLATE_BG: Color = Color(0.035, 0.032, 0.028, 0.96)
const PLATE_BORDER: Color = Color(0.45, 0.4, 0.32)
const TEXT: Color = Color(0.93, 0.9, 0.84)
const DIM_TEXT: Color = Color(0.55, 0.53, 0.5)

## The tray the dice fly into, px; they rest in a row across its middle. A
## die's centre starts at least TRAY_INSET from its sides, so a corner
## spinning past stays on the card.
const TRAY_SIZE: Vector2 = Vector2(720.0, 380.0)
const TRAY_INSET: float = 72.0
## Two dice never come closer than this many faces, centre to centre (a
## cube turned corner-on is about 1.4 faces across).
const MIN_APART_FACES: float = 1.45
## A throw-in heads at most THROW_IN_TURN off the way its throw comes down,
## at THROW_IN_SPEED times the throw's own speed there (the touchdown
## sheds the rest), and starts at most a face below the tray.
const THROW_IN_TURN: float = deg_to_rad(40.0)
const THROW_IN_SPEED: Vector2 = Vector2(1.0, 2.5)
## Routes are redrawn up to this many times to clear each other (a few
## usually do); failing that the dice fly their throws' own paths, which
## d6_throws.py cleared.
const ROUTE_TRIES: int = 400
## The throw lands for good (height within this of rest) at its arrival,
## and any dip in its height that it climbs out of by BOUNCE_RISE before
## then is a bounce; bounces closer than MIN_LEG_FRAMES (to each other, the
## launch or the arrival) count as one.
const ARRIVE_HEIGHT: float = 1.0
const BOUNCE_RISE: float = 0.2
const MIN_LEG_FRAMES: int = 4
## Room either side of the dice for the verdict row and line, px.
const VERDICT_PAD: float = 60.0
## The total plate; the verdict row is this tall, and the target plate
## beside it fits inside that height.
const TOTAL_PLATE_SIZE: Vector2 = Vector2(120.0, 64.0)
const COLUMN_SEPARATION: int = 8
const CARD_MARGIN: float = 14.0
## Lines the verdict label always keeps room for.
const RESULT_LINES: int = 2
## Centred in the screen above the conversation band. _BAND_CLEARANCE is
## the room the content-sized band needs at the bottom, plus a gap.
const _BAND_CLEARANCE: float = 170.0

## From the sidecar, which overrides these at _ready; these are only what
## the scripts wrote last and what the layout falls back on without it.
var _cell: int = 208
var _cols: int = 8
var _fps: float = 30.0
var _face_px: float = 96.0
var _glint_frames: int = 10
var _launch_frames: Array[int] = [0, 4, 8]
var _slot_spacing: float = 153.6
## One per throw: {frames: int, path: PackedVector3Array}, path one entry
## per frame, px from rest, screen y down, z = height above rest. Throw i
## ending on face n plays d6_roll_<i>_<n>.png, `frames` cells, the last of
## them the rest still of n. Empty when the sidecar did not load, and then
## a roll skips straight to its result.
var _heads: Array[Dictionary] = []
## Sheets by file name, loaded the first time a roll needs them.
var _sheets: Dictionary = {}
## Sheets asked of ResourceLoader on a thread and not collected yet.
var _requested: Dictionary = {}

var _card: PanelContainer
var _target_plate: PanelContainer
var _target_style: StyleBoxFlat
var _skill_label: Label
var _target_label: Label
## The tray. Plain Control, so its children (the dice) are positioned by
## hand.
var _dice_row: Control
## Holds _total_plate's place in the verdict row; the plate itself is a
## free child of it, so it can pop and slam without a container resetting
## it.
var _total_holder: Control
var _total_plate: PanelContainer
var _total_style: StyleBoxFlat
var _total_label: Label
var _result_label: Label
var _continue_button: Button

## Per slot. _bodies is the die's own texture (its roll sheet, then the
## blank still); the numeral and glint are layers over it.
var _dice: Array[Control] = []
var _bodies: Array[AtlasTexture] = []
var _numerals: Array[TextureRect] = []
var _glints: Array[TextureRect] = []
var _shadows: Array[TextureRect] = []
var _slot_head: Array[int] = [0, 0, 0]
var _slot_value: Array[int] = [1, 1, 1]
var _roll_sheets: Array[Texture2D] = [null, null, null]
var _landed: Array[bool] = [false, false, false]
var _heights: Array[float] = [0.0, 0.0, 0.0]
## This roll's route per slot: the die's offset from its slot's rest at
## each sheet frame (the height stays the throw's own).
var _routes: Array[PackedVector2Array] = [PackedVector2Array(), PackedVector2Array(), PackedVector2Array()]
var _rng := RandomNumberGenerator.new()
var _running_total: int = 0
## True from Roll until the resolved state: a click on the card skips.
var _animating: bool = false

## The running roll's tweens, killed when a roll is skipped, abandoned or
## restarted.
var _tweens: Array[Tween] = []
## The conversation this is attached to as its &"dice" presenter, and the
## serial of the last wait it started playing, so one wait plays once even
## though `changed` fires many times while it is up.
var _conversation: Conversation = null
var _played_serial: int = -1
## Bumped by every roll that starts and by _forget. A roll coroutine checks
## it after each wait and stops the moment it has changed, so a roll whose
## conversation ended (or moved on) mid-throw or while waiting on a press
## neither stays on screen nor shares the next roll's button press.
var _play_token: int = 0

## One step of a roll: the button was pressed, an animation finished or
## was skipped, or the roll was abandoned. The coroutine waits on this
## rather than on the button itself so _forget can wake it up to leave.
signal _step


func _ready() -> void:
	visible = false
	_load_sidecar()
	_build_scene()
	Conversations.follow(self, _on_conversation_began)


func _exit_tree() -> void:
	_forget()


## Attached to every conversation, whatever its presentation — a skill
## check asks for dice, not for a dialogue. Attaching is what makes a
## check wait at all; with nothing attached Conversation.show returns at
## once, which is what a test with no UI relies on.
func _on_conversation_began(c: Conversation) -> void:
	_forget()
	_conversation = c
	_played_serial = -1
	c.attach(&"dice", self)
	c.changed.connect(_on_changed)
	# Picked up mid-conversation, a wait may already be up.
	_on_changed()


func _on_changed() -> void:
	var c: Conversation = _conversation
	if c == null:
		return
	if c.ended:
		_forget()
		return
	# The wait on screen was completed by someone else (finish_dice, another
	# presenter's detach): let its roll go, or its parked coroutine would
	# wake on the next roll's button press. The popup hides itself before
	# its own complete(), so that one never lands here.
	if visible and c.waiting.get("serial") != _played_serial:
		_abandon_roll()
	if c.waiting.get("kind") != &"dice" or c.waiting.serial == _played_serial:
		return
	var serial: int = c.waiting.serial
	_played_serial = serial
	var data: Dictionary = c.waiting.data
	await _on_dice_roll_requested(data.skill, data.roll)
	# Only the wait this played is completed: if the conversation ended or
	# moved on while the dice were up, completing now would release a
	# different wait. `serial`, not _played_serial, which a later wait may
	# already have taken.
	if c == _conversation and c.waiting.get("serial") == serial:
		c.complete()


## Also abandons a roll still on screen: the conversation it was for is
## gone, so nothing will ever complete it, and a parked coroutine left
## waiting on the button would otherwise be released by the NEXT
## conversation's roll along with its own.
func _forget() -> void:
	if _conversation:
		_conversation.detach(&"dice", self)
		if _conversation.changed.is_connected(_on_changed):
			_conversation.changed.disconnect(_on_changed)
	_conversation = null
	_abandon_roll()


## Stops whatever roll is up and wakes its coroutine so it sees the bumped
## token and leaves.
func _abandon_roll() -> void:
	_play_token += 1
	_animating = false
	_kill_tweens()
	visible = false
	if _continue_button:
		_continue_button.visible = false
	_step.emit()


# --- The roll ------------------------------------------------------

func _on_dice_roll_requested(skill_name: String, roll: Dictionary) -> void:
	_play_token += 1
	var token: int = _play_token
	visible = true
	_animating = false
	_kill_tweens()
	_show_idle(skill_name, roll)
	_continue_button.text = "Roll"
	_continue_button.visible = true
	await _step
	if token != _play_token:
		return

	_continue_button.visible = false
	_result_label.text = "Rolling %s..." % skill_name
	_animating = true
	# A skip clears _animating, kills the tweens and steps, so whichever
	# animation is playing ends at once and the next one never starts.
	var throw: Tween = _start_throw(roll)
	if throw == null:
		_animating = false
	else:
		throw.finished.connect(_step.emit)
		await _step
		if token != _play_token:
			return
	if _animating:
		var slam: Tween = _start_slam(roll)
		slam.finished.connect(_step.emit)
		await _step
		if token != _play_token:
			return
	_animating = false
	_kill_tweens()
	_show_resolved(roll)

	_continue_button.text = "Continue"
	_continue_button.visible = true
	await _step
	if token != _play_token:
		return
	visible = false


func _on_card_gui_input(event: InputEvent) -> void:
	var click := event as InputEventMouseButton
	if not _animating or click == null or not click.pressed or click.button_index != MOUSE_BUTTON_LEFT:
		return
	_card.accept_event()
	_animating = false
	_kill_tweens()
	_step.emit()


## Three different throws, one per slot, in random slot order, picked at
## idle so their sheets load on a thread while the player reads the Roll
## prompt rather than on the frame the throw starts.
func _pick_throws(roll: Dictionary) -> void:
	if _heads.size() < SLOTS:
		return
	var order: Array = range(_heads.size())
	order.shuffle()
	for k in SLOTS:
		_slot_head[k] = order[k]
		_slot_value[k] = roll.dice[k]
		_request_sheet(_roll_sheet_name(_slot_head[k], _slot_value[k]))
	_request_sheet(GLINT_SHEET)
	_request_sheet(STILL_BLANK_SHEET)
	_request_sheet(NUMERALS_SHEET)


static func _roll_sheet_name(head: int, value: int) -> String:
	return "d6_roll_%d_%d.png" % [head, value]


## Each die plays its throw's roll for the face it rolled, launch to rest.
func _start_throw(roll: Dictionary) -> Tween:
	if _heads.size() < SLOTS:
		return null
	var frames: int = 0
	for k in SLOTS:
		var head: int = _slot_head[k]
		var value: int = roll.dice[k]
		_slot_value[k] = value
		_landed[k] = false
		_roll_sheets[k] = _sheet(_roll_sheet_name(head, value))
		_numerals[k].visible = false
		_glints[k].visible = false
		var spec: Dictionary = _heads[head]
		frames = maxi(frames, _launch_frames[k] + spec.frames + _glint_frames)
	_plan_routes()
	var duration: float = frames / _fps
	var tween: Tween = _new_tween()
	_show_time(0.0)
	tween.tween_method(_show_time, 0.0, duration, duration)
	return tween


## Every die at `t` seconds after the first launch.
func _show_time(t: float) -> void:
	for k in SLOTS:
		_show_die(k, t * _fps - _launch_frames[k])
	_sort_dice_by_height()


## Die k, `local` frames after its own launch (negative: not thrown yet).
func _show_die(k: int, local: float) -> void:
	if local < 0.0:
		_dice[k].visible = false
		_shadows[k].visible = false
		return
	var spec: Dictionary = _heads[_slot_head[k]]
	# The roll's last frame is the rest still, so the die lands on it.
	var last: int = spec.frames - 1
	var raw: int = floori(local)
	var frame: int = mini(raw, last)
	if frame < last:
		_show_cell(k, _roll_sheets[k], frame)
	elif not _landed[k]:
		_land(k)
	var path: PackedVector3Array = spec.path
	var route: PackedVector2Array = _routes[k]
	var at: Vector2 = route[mini(frame, route.size() - 1)]
	var z: float = path[mini(frame, path.size() - 1)].z
	_place_die(k, Vector3(at.x, at.y, z), clampf(local / FADE_IN_FRAMES, 0.0, 1.0))
	_show_glint(k, raw - last - 1)


func _land(k: int) -> void:
	_landed[k] = true
	_show_still(k)
	_running_total += _slot_value[k]
	_total_label.text = str(_running_total)
	_total_label.add_theme_color_override("font_color", TEXT)
	_total_plate.scale = Vector2.ONE * POP_SCALE
	var tween: Tween = _new_tween()
	tween.tween_property(_total_plate, "scale", Vector2.ONE, POP_TIME) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


## The total flies sideways along the verdict row into the target plate,
## the verdict lands with it, and the total springs back to its place. It
## never leaves its own row, so the dice above are never covered.
func _start_slam(roll: Dictionary) -> Tween:
	# Scaled about its centre, the plate's drawn left edge moves out by half
	# its growth; stop that edge, not the unscaled one, SLAM_GAP short of
	# the target's right edge.
	var reach: float = _target_plate.get_global_rect().end.x + SLAM_GAP \
		+ TOTAL_PLATE_SIZE.x * (SLAM_SCALE - 1.0) * 0.5 \
		- _total_holder.get_global_rect().position.x
	_total_plate.z_index = 2
	var tween: Tween = _new_tween()
	tween.tween_interval(VERDICT_DELAY)
	tween.tween_property(_total_plate, "position:x", reach, SLAM_TIME) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(_total_plate, "scale", Vector2.ONE * SLAM_SCALE, SLAM_TIME)
	tween.tween_callback(_apply_verdict.bind(roll))
	tween.tween_interval(SLAM_HOLD)
	tween.tween_property(_total_plate, "position:x", 0.0, SLAM_RETURN_TIME) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(_total_plate, "scale", Vector2.ONE, SLAM_RETURN_TIME)
	return tween


# --- States ----------------------------------------------------------

func _show_idle(skill_name: String, roll: Dictionary) -> void:
	_skill_label.text = skill_name
	_target_label.text = str(roll.target)
	_result_label.text = "%s check" % skill_name
	_result_label.remove_theme_color_override("font_color")
	_target_style.border_color = PLATE_BORDER
	_total_style.border_color = PLATE_BORDER
	_pick_throws(roll)
	_running_total = 0
	_total_label.text = "—"
	_total_label.add_theme_color_override("font_color", DIM_TEXT)
	_reset_total_plate()
	for k in SLOTS:
		_landed[k] = false
		_show_still(k)
		_numerals[k].visible = false
		_numerals[k].modulate = Color.WHITE
		_glints[k].visible = false
		_place_die(k, Vector3.ZERO, IDLE_GHOST_ALPHA)
		_shadows[k].visible = false


## Every die at rest on its face, the total in, the verdict shown — where
## a roll ends, played out or skipped.
func _show_resolved(roll: Dictionary) -> void:
	for k in SLOTS:
		_slot_value[k] = roll.dice[k]
		_landed[k] = true
		_show_still(k)
		_glints[k].visible = false
		_place_die(k, Vector3.ZERO, 1.0)
	_running_total = roll.roll
	_total_label.text = str(roll.roll)
	_reset_total_plate()
	_apply_verdict(roll)


func _apply_verdict(roll: Dictionary) -> void:
	var colour: Color = GOLD if roll.success else RED
	_target_style.border_color = colour
	_total_style.border_color = colour
	_total_label.add_theme_color_override("font_color", colour)
	_result_label.add_theme_color_override("font_color", colour)
	_result_label.text = _verdict_text(roll)
	var tint: Color = Color.WHITE
	if roll.critical_success:
		tint = CRIT_SUCCESS_TINT
	elif roll.critical_failure:
		tint = CRIT_FAILURE_TINT
	for numeral in _numerals:
		numeral.modulate = tint


## "Success by 3 — 9 vs 12": the margin is always a positive count of how
## far the roll cleared or missed, and is left out when it has none (a
## critical can succeed above the target or fail below it).
static func _verdict_text(roll: Dictionary) -> String:
	var success: bool = roll.success
	var word: String = "Success" if success else "Failure"
	if roll.critical_success or roll.critical_failure:
		word = "Critical " + word
	var margin: int = roll.target - roll.roll if success else roll.roll - roll.target
	if margin > 0:
		word += " by %d" % margin
	return "%s — %d vs %d" % [word, roll.roll, roll.target]


func _reset_total_plate() -> void:
	_total_plate.position = Vector2.ZERO
	_total_plate.scale = Vector2.ONE
	_total_plate.z_index = 0


# --- Dice drawing ----------------------------------------------------

func _show_cell(k: int, sheet: Texture2D, index: int) -> void:
	_bodies[k].atlas = sheet
	_bodies[k].region = _cell_rect(index)


## The blank still with its numeral on top.
func _show_still(k: int) -> void:
	_show_cell(k, _sheet(STILL_BLANK_SHEET), 0)
	var numeral := _numerals[k].texture as AtlasTexture
	numeral.atlas = _sheet(NUMERALS_SHEET)
	numeral.region = _cell_rect(_slot_value[k] - 1)
	_numerals[k].visible = true


func _show_glint(k: int, index: int) -> void:
	var glint: TextureRect = _glints[k]
	glint.visible = index >= 0 and index < _glint_frames
	if glint.visible:
		var tex := glint.texture as AtlasTexture
		tex.atlas = _sheet(GLINT_SHEET)
		tex.region = _cell_rect(index)


## Die k (and its shadow) at path point `p` from its slot's rest.
func _place_die(k: int, p: Vector3, alpha: float) -> void:
	var centre: Vector2 = _slot_centre(k) + Vector2(p.x, p.y)
	var die: Control = _dice[k]
	die.visible = true
	die.modulate.a = alpha
	# Whole pixels: the sprites are drawn 1:1 and would blur between them.
	die.position = (centre - Vector2(_cell, _cell) * 0.5).round()
	_heights[k] = p.z
	var z: float = maxf(p.z, 0.0)
	var shadow: TextureRect = _shadows[k]
	shadow.visible = true
	shadow.size = SHADOW_SIZE * (1.0 + z * SHADOW_GROW_PER_Z)
	shadow.position = (centre + SHADOW_REST_OFFSET + SHADOW_OFFSET_PER_Z * z - shadow.size * 0.5).round()
	shadow.modulate.a = SHADOW_ALPHA * alpha * clampf(1.0 - z * SHADOW_FADE_PER_Z, SHADOW_MIN_FADE, 1.0)


## Rest centre of slot k in _dice_row's own space. From its minimum size,
## which is its size too (it shrinks to it), and known before any layout.
func _slot_centre(k: int) -> Vector2:
	var row: Vector2 = _dice_row.custom_minimum_size
	return Vector2(row.x * 0.5 + (k - (SLOTS - 1) * 0.5) * _slot_spacing, row.y * 0.5)


## Higher dice draw on top where they cross. The shadows are the row's
## first SLOTS children, the dice the next SLOTS.
func _sort_dice_by_height() -> void:
	var order: Array = range(SLOTS)
	order.sort_custom(func(a: int, b: int) -> bool: return _heights[a] < _heights[b])
	for rank in SLOTS:
		var die: Control = _dice[order[rank]]
		if die.get_index() != SLOTS + rank:
			_dice_row.move_child(die, SLOTS + rank)


func _cell_rect(index: int) -> Rect2:
	return Rect2((index % _cols) * _cell, floori(float(index) / _cols) * _cell, _cell, _cell)


## A sheet by file name: from the cache, from its threaded load (which
## blocks only if that has not finished yet), or loaded on the spot.
func _sheet(file: String) -> Texture2D:
	if not _sheets.has(file):
		if _requested.has(file):
			_requested.erase(file)
			_sheets[file] = ResourceLoader.load_threaded_get(DICE_DIR + file)
		else:
			_sheets[file] = load(DICE_DIR + file)
	return _sheets[file]


func _request_sheet(file: String) -> void:
	if _sheets.has(file) or _requested.has(file):
		return
	if ResourceLoader.load_threaded_request(DICE_DIR + file) == OK:
		_requested[file] = true


## A route per slot for this roll, redrawn until no two dice ever come
## within MIN_APART_FACES of each other, in flight or at rest; failing
## that, the throws' own paths.
func _plan_routes() -> void:
	_rng.randomize()
	for _try in ROUTE_TRIES:
		var drawn: bool = true
		for k in SLOTS:
			_routes[k] = _random_route(k)
			drawn = drawn and not _routes[k].is_empty()
		if drawn and _routes_clear():
			return
	push_warning("skill_check_dice_popup: no clear routes in %d tries; the dice fly their throws' own paths" % ROUTE_TRIES)
	for k in SLOTS:
		var own := PackedVector2Array()
		for p in _heads[_slot_head[k]].path:
			own.append(Vector2(p.x, p.y))
		_routes[k] = own


## Die k's route, as its offset from its slot at every sheet frame: a
## straight flight in to its throw's first touchdown, then the throw's own
## path. Kept when the flight starts within the tray's width, below the
## row and at most a face below the tray; empty when no draw did in a few
## goes.
func _random_route(k: int) -> PackedVector2Array:
	var path: PackedVector3Array = _heads[_slot_head[k]].path
	var touch: int = _key_frames(path)[1]
	var slot: Vector2 = _slot_centre(k)
	var land: Vector2 = slot + Vector2(path[touch].x, path[touch].y)
	# The throw's own speed coming down, px per frame, over its last two
	# frames in the air.
	var back: int = maxi(touch - 2, 0)
	var coming: Vector2 = (land - slot - Vector2(path[back].x, path[back].y)) / (touch - back)
	if coming.is_zero_approx():
		coming = Vector2.UP
	for _go in 50:
		var turn: float = _rng.randf_range(-THROW_IN_TURN, THROW_IN_TURN)
		var speed: float = _rng.randf_range(THROW_IN_SPEED.x, THROW_IN_SPEED.y)
		var start: Vector2 = land - coming.rotated(turn) * speed * touch
		var inside: bool = start.x >= TRAY_INSET and start.x <= TRAY_SIZE.x - TRAY_INSET
		if not inside or start.y < slot.y or start.y > TRAY_SIZE.y + _face_px:
			continue
		var route := PackedVector2Array()
		for f in path.size():
			if f < touch:
				route.append(start.lerp(land, float(f) / touch) - slot)
			else:
				route.append(Vector2(path[f].x, path[f].y))
		return route
	return PackedVector2Array()


## Launch, every bounce, and the landing for good, as frames of `path`.
static func _key_frames(path: PackedVector3Array) -> Array[int]:
	var arrive: int = path.size() - 1
	for f in path.size():
		if path[f].z <= ARRIVE_HEIGHT:
			arrive = f
			break
	var keys: Array[int] = [0]
	for f in range(1, arrive):
		var z: float = path[f].z
		if not (z < path[f - 1].z and z <= path[f + 1].z):
			continue
		# A bounce climbs out of the dip; a tumble that only slows its fall
		# does not.
		var peak: float = z
		var j: int = f + 1
		while j < arrive and path[j].z >= z:
			peak = maxf(peak, path[j].z)
			j += 1
		if peak - z < BOUNCE_RISE or f < MIN_LEG_FRAMES:
			continue
		# Two bounces too close together are one: keep the lower.
		if keys.size() > 1 and f - keys[-1] < MIN_LEG_FRAMES:
			if z < path[keys[-1]].z:
				keys[-1] = f
			continue
		keys.append(f)
	while keys.size() > 1 and arrive - keys[-1] < MIN_LEG_FRAMES:
		keys.pop_back()
	keys.append(maxi(arrive, 1))
	return keys


## True when no two dice in the tray are ever closer than MIN_APART_FACES,
## counting each die from its launch and holding it at rest once landed.
func _routes_clear() -> bool:
	var apart: float = MIN_APART_FACES * _face_px
	var span: int = 0
	for k in SLOTS:
		span = maxi(span, _launch_frames[k] + _routes[k].size())
	for frame in span:
		for a in SLOTS:
			var la: int = frame - _launch_frames[a]
			if la < 0:
				continue
			var pa: Vector2 = _slot_centre(a) + _routes[a][mini(la, _routes[a].size() - 1)]
			for b in range(a + 1, SLOTS):
				var lb: int = frame - _launch_frames[b]
				if lb < 0:
					continue
				var pb: Vector2 = _slot_centre(b) + _routes[b][mini(lb, _routes[b].size() - 1)]
				if pa.distance_to(pb) < apart:
					return false
	return true


func _new_tween() -> Tween:
	var tween: Tween = create_tween()
	_tweens.append(tween)
	return tween


func _kill_tweens() -> void:
	for tween in _tweens:
		if tween.is_valid():
			tween.kill()
	_tweens.clear()


# --- Setup -----------------------------------------------------------

func _load_sidecar() -> void:
	if not FileAccess.file_exists(SIDECAR_PATH):
		push_error("skill_check_dice_popup: %s missing; rolls will skip to their result" % SIDECAR_PATH)
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(SIDECAR_PATH))
	if typeof(data) != TYPE_DICTIONARY:
		push_error("skill_check_dice_popup: %s is not a JSON object" % SIDECAR_PATH)
		return
	_cell = int(data.get("cell", _cell))
	_cols = int(data.get("cols", _cols))
	_fps = float(data.get("fps", _fps))
	_face_px = float(data.get("face_px", _face_px))
	_glint_frames = int(data.get("glint_frames", _glint_frames))
	_slot_spacing = float(data.get("slot_spacing_px", _slot_spacing))
	var launch: Array = data.get("launch_frames", [])
	if launch.size() >= SLOTS:
		_launch_frames.clear()
		for frame in launch:
			_launch_frames.append(int(frame))
	for head in data.get("heads", []):
		var path := PackedVector3Array()
		for p in head.get("path", []):
			path.append(Vector3(p[0], p[1], p[2]))
		var spec: Dictionary = {"frames": int(head.get("frames", 0)), "path": path}
		if spec.frames < 1 or path.is_empty():
			push_error("skill_check_dice_popup: %s has an empty throw (or one in the old head/tail format); rolls will skip to their result" % SIDECAR_PATH)
			_heads.clear()
			return
		if path.size() != spec.frames:
			push_warning("skill_check_dice_popup: a throw's path has %d frames, its sheet %d" % [path.size(), spec.frames])
		_heads.append(spec)
	if _heads.size() < SLOTS:
		push_error("skill_check_dice_popup: %s has %d throws, needs %d" % [SIDECAR_PATH, _heads.size(), SLOTS])
		_heads.clear()


func _build_scene() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_card = PanelContainer.new()
	add_child(_card)
	_card.anchor_left = 0.5
	_card.anchor_top = 0.5
	_card.anchor_right = 0.5
	_card.anchor_bottom = 0.5
	_card.offset_top = -_BAND_CLEARANCE * 0.5
	_card.offset_bottom = -_BAND_CLEARANCE * 0.5
	_card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_card.grow_vertical = Control.GROW_DIRECTION_BOTH
	_card.mouse_filter = Control.MOUSE_FILTER_STOP
	_card.add_theme_stylebox_override("panel", _box(CARD_BG, CARD_BG, 0, 10, CARD_MARGIN))
	_card.gui_input.connect(_on_card_gui_input)

	var column := VBoxContainer.new()
	_card.add_child(column)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", COLUMN_SEPARATION)

	_dice_row = Control.new()
	column.add_child(_dice_row)
	_dice_row.custom_minimum_size = TRAY_SIZE
	_dice_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_dice_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Over the rows below, should a spinning corner reach them.
	_dice_row.z_index = 1
	# 1:1 sprites, so no mipmaps; linear only for the subpixel shadow.
	_dice_row.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_build_dice()

	# Target left, total right, the row a little wider than the resting
	# dice: the slam crosses the gap between them.
	var row_width: float = (SLOTS - 1) * _slot_spacing + _face_px + 2 * VERDICT_PAD
	var verdict_row := HBoxContainer.new()
	column.add_child(verdict_row)
	verdict_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	verdict_row.custom_minimum_size = Vector2(row_width, TOTAL_PLATE_SIZE.y)
	verdict_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	_target_style = _box(PLATE_BG, PLATE_BORDER, 2, 6, 10)
	_target_plate = _plate(verdict_row, _target_style)
	_target_plate.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var target_row := HBoxContainer.new()
	_target_plate.add_child(target_row)
	target_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	target_row.add_theme_constant_override("separation", 14)
	_skill_label = _label(target_row, 18, TEXT)
	_target_label = _label(target_row, 30, GOLD)

	var gap := Control.new()
	verdict_row.add_child(gap)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_total_holder = Control.new()
	verdict_row.add_child(_total_holder)
	_total_holder.custom_minimum_size = TOTAL_PLATE_SIZE
	_total_holder.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_total_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_total_style = _box(PLATE_BG, PLATE_BORDER, 2, 6, 6)
	_total_plate = _plate(_total_holder, _total_style)
	_total_plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_total_plate.pivot_offset = TOTAL_PLATE_SIZE * 0.5
	_total_label = _label(_total_plate, 34, DIM_TEXT)

	# The card is centred, so anything that changes its height moves the
	# slots under resting dice. The verdict keeps room for two lines and the
	# button keeps its place while hidden.
	_result_label = _label(column, 18, TEXT)
	_result_label.remove_theme_color_override("font_color")
	# Word-wraps inside the dice row's width instead of widening the card.
	_result_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_result_label.max_lines_visible = RESULT_LINES
	var line: float = _result_label.get_theme_font("font").get_height(18) \
		+ _result_label.get_theme_constant("line_spacing")
	_result_label.custom_minimum_size = Vector2(row_width, ceilf(line * RESULT_LINES))

	var button_holder := CenterContainer.new()
	column.add_child(button_holder)
	button_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_continue_button = Button.new()
	button_holder.add_child(_continue_button)
	_continue_button.text = "Continue"
	_continue_button.custom_minimum_size = Vector2(120, 0)
	button_holder.custom_minimum_size = _continue_button.get_combined_minimum_size()
	_continue_button.visible = false
	_continue_button.pressed.connect(_step.emit)


## Shadows first, then the dice, so every shadow is under every die.
func _build_dice() -> void:
	var shadow_texture: Texture2D = _make_shadow_texture()
	for _slot in SLOTS:
		var shadow := TextureRect.new()
		_dice_row.add_child(shadow)
		shadow.texture = shadow_texture
		shadow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		shadow.stretch_mode = TextureRect.STRETCH_SCALE
		shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		shadow.visible = false
		_shadows.append(shadow)
	var additive := CanvasItemMaterial.new()
	additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	for _slot in SLOTS:
		var die := Control.new()
		_dice_row.add_child(die)
		die.size = Vector2(_cell, _cell)
		die.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var body := AtlasTexture.new()
		_bodies.append(body)
		_layer(die, body)
		_numerals.append(_layer(die, AtlasTexture.new()))
		var glint: TextureRect = _layer(die, AtlasTexture.new())
		glint.material = additive
		_glints.append(glint)
		_dice.append(die)


## One cell-sized sprite layer of a die, drawn at its texture's own size.
func _layer(die: Control, texture: AtlasTexture) -> TextureRect:
	var rect := TextureRect.new()
	die.add_child(rect)
	rect.texture = texture
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP
	rect.size = Vector2(_cell, _cell)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


## A soft round blob, stretched to an ellipse by its TextureRect.
static func _make_shadow_texture() -> Texture2D:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.6, 1.0])
	gradient.colors = PackedColorArray([Color(0, 0, 0, 1), Color(0, 0, 0, 0.8), Color(0, 0, 0, 0)])
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(0.5, 0.0)
	texture.width = 64
	texture.height = 64
	return texture


static func _box(bg: Color, border: Color, border_width: int, radius: int, margin: float) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.border_color = border
	box.set_border_width_all(border_width)
	box.set_corner_radius_all(radius)
	box.set_content_margin_all(margin)
	return box


static func _plate(parent: Control, style: StyleBoxFlat) -> PanelContainer:
	var plate := PanelContainer.new()
	parent.add_child(plate)
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.add_theme_stylebox_override("panel", style)
	return plate


static func _label(parent: Control, font_size: int, colour: Color) -> Label:
	var label := Label.new()
	parent.add_child(label)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", colour)
	return label
