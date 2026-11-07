extends Control
## Shows a 3d6 tumble for a dialogue skill check, landing on the exact
## faces SuccessRoll.roll_vs() already rolled — a check asks for it with
## Conversation.show(&"dice", {skill, roll}), which parks the choice until
## this calls Conversation.complete(). The roll is fully decided before
## this ever runs; this only plays back an already-final result.
##
## BG3-style sprite dice, no 3D in game: every die is a TextureRect whose
## AtlasTexture steps through pre-rendered sheets in assets/ui/dice/ —
## a result-agnostic tumble loop (one per die, so the three never move
## in unison), then the settle sheet for the face that die rolled (it
## comes to rest face-up and a glint crosses it), then the landed still.
## The sheets are rendered by tools/dice/render_d6_sheets.py in Blender
## and packed by tools/dice/pack_d6_sheets.py (tools/dice/build.sh runs
## both); the frame size and grids below must match those scripts.
##
## Hidden by default. MainRoot.tscn adds exactly one of these as a
## CanvasLayer child, after DialogueOverlay/ConversationLog so it
## renders on top of both while a roll is in progress.

const FRAME_PX: int = 192
const FPS: float = 30.0
const TUMBLE_SHEETS: Array[Texture2D] = [
	preload("res://assets/ui/dice/d6_tumble_a.png"),
	preload("res://assets/ui/dice/d6_tumble_b.png"),
	preload("res://assets/ui/dice/d6_tumble_c.png"),
]
const TUMBLE_COLS: int = 8
const TUMBLE_FRAMES: int = 32
## Index = face value - 1.
const SETTLE_SHEETS: Array[Texture2D] = [
	preload("res://assets/ui/dice/d6_settle_1.png"),
	preload("res://assets/ui/dice/d6_settle_2.png"),
	preload("res://assets/ui/dice/d6_settle_3.png"),
	preload("res://assets/ui/dice/d6_settle_4.png"),
	preload("res://assets/ui/dice/d6_settle_5.png"),
	preload("res://assets/ui/dice/d6_settle_6.png"),
]
const SETTLE_COLS: int = 4
const SETTLE_FRAMES: int = 16
## One row, faces 1..6 left to right.
const LANDED_SHEET: Texture2D = preload("res://assets/ui/dice/d6_landed.png")

## On-screen size of one frame. The die itself fills under half of it;
## the rest is room for the tumble and the shadow.
const DIE_DISPLAY_PX: float = 120.0
## Neighbouring frames overlap by this much, since their edges are empty.
const DIE_OVERLAP_PX: float = 34.0
## Time from Roll to the FIRST die coming to rest, settle included.
const TUMBLE_DURATION: float = 1.0
## Each die lands this much later than the previous one, so all 3
## visibly stop in sequence instead of landing in a near-unison blur.
const STAGGER_STEP: float = 0.4
## Arbitrary — the roll hasn't happened yet, so no face value is
## "correct" while waiting on the Roll button. Each die just shows its
## landed still of this face.
const IDLE_FACE_VALUE: int = 1
## Bottom-right, in a small footprint above the conversation band, rather
## than dead centre over the speaker, which the lower-third layout keeps
## clear. Anchored to the BOTTOM of the screen: _BAND_CLEARANCE is the
## room the content-sized band needs there, its own height plus a gap.
## If the band ever grows past it (a very long choice list), the dice
## overlap it rather than the speaker, the better of the two failures.
##
## Both anchors on each axis are equal, so the size is exactly the
## offsets: a fixed _CORNER_WIDTH x _CORNER_HEIGHT box pinned to that
## corner as the window resizes.
const _CORNER_WIDTH: float = 3 * DIE_DISPLAY_PX - 2 * DIE_OVERLAP_PX + 16.0
const _CORNER_HEIGHT: float = 190.0
const _CORNER_MARGIN: float = 20.0
## Height the conversation band needs at the bottom, plus a gap above it.
const _BAND_CLEARANCE: float = 170.0

## One AtlasTexture per die, each the texture of its own TextureRect;
## showing a frame only moves its atlas and region.
var _faces: Array[AtlasTexture] = []
## The running roll's tweens, killed when a roll is abandoned or restarted.
var _tweens: Array[Tween] = []
var _result_label: Label
var _continue_button: Button
## The conversation this is attached to as its &"dice" presenter, and the
## serial of the last wait it started playing, so one wait plays once even
## though `changed` fires many times while it is up.
var _conversation: Conversation = null
var _played_serial: int = -1
## Bumped by every roll that starts and by _forget. A roll coroutine checks
## it after each wait and stops the moment it has changed, so a roll whose
## conversation ended (or moved on) mid-tumble or while waiting on a press
## neither stays on screen nor shares the next roll's button press.
var _play_token: int = 0

## One step of a roll: the button was pressed, or the roll was abandoned.
## The coroutine waits on this rather than on the button itself so _forget
## can wake it up to leave.
signal _step


func _ready() -> void:
	visible = false
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
	if c.waiting.get("kind") != &"dice" or c.waiting.serial == _played_serial:
		return
	_played_serial = c.waiting.serial
	var data: Dictionary = c.waiting.data
	await _on_dice_roll_requested(data.skill, data.roll)
	# Only the wait this played is completed: if the conversation ended or
	# moved on while the dice were up, completing now would release a
	# different wait.
	if c == _conversation and c.waiting.get("serial") == _played_serial:
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
	_play_token += 1
	_kill_tweens()
	visible = false
	if _continue_button:
		_continue_button.visible = false
	_step.emit()


func _build_scene() -> void:
	anchor_left = 1.0
	anchor_top = 1.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = -(_CORNER_WIDTH + _CORNER_MARGIN)
	offset_top = -(_CORNER_HEIGHT + _BAND_CLEARANCE)
	offset_right = -_CORNER_MARGIN
	offset_bottom = -_BAND_CLEARANCE
	custom_minimum_size = Vector2(_CORNER_WIDTH, _CORNER_HEIGHT)

	var panel := PanelContainer.new()
	add_child(panel)

	var vbox := VBoxContainer.new()
	panel.add_child(vbox)

	var row := HBoxContainer.new()
	vbox.add_child(row)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", -int(DIE_OVERLAP_PX))
	for i in 3:
		var face := AtlasTexture.new()
		_faces.append(face)
		var die := TextureRect.new()
		row.add_child(die)
		die.texture = face
		die.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		die.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		die.custom_minimum_size = Vector2(DIE_DISPLAY_PX, DIE_DISPLAY_PX)
		# The sheets carry mipmaps: frames are drawn well under the size
		# they were rendered at.
		die.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		_show_landed(i, IDLE_FACE_VALUE)

	_result_label = Label.new()
	vbox.add_child(_result_label)
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_label.add_theme_font_size_override("font_size", 12)
	# Word-wraps ("Critical success! — 14 vs 10" etc.) inside the dice
	# row's width instead of forcing the popup wider than its corner box.
	_result_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_result_label.custom_minimum_size = Vector2(_CORNER_WIDTH - 16.0, 0)

	_continue_button = Button.new()
	vbox.add_child(_continue_button)
	_continue_button.text = "Continue"
	_continue_button.visible = false
	_continue_button.pressed.connect(_step.emit)


func _show_frame(die: int, sheet: Texture2D, cols: int, index: int) -> void:
	var face: AtlasTexture = _faces[die]
	face.atlas = sheet
	face.region = Rect2((index % cols) * FRAME_PX, floori(float(index) / cols) * FRAME_PX, FRAME_PX, FRAME_PX)


## `frame` counts up without wrapping; the tumble sheet is a seamless loop.
func _show_tumble(frame: float, die: int, phase: int) -> void:
	_show_frame(die, TUMBLE_SHEETS[die], TUMBLE_COLS, (int(frame) + phase) % TUMBLE_FRAMES)


func _show_settle(frame: float, die: int, face_value: int) -> void:
	_show_frame(die, SETTLE_SHEETS[face_value - 1], SETTLE_COLS, mini(int(frame), SETTLE_FRAMES - 1))


func _show_landed(die: int, face_value: int) -> void:
	_show_frame(die, LANDED_SHEET, 6, face_value - 1)


func _kill_tweens() -> void:
	for tween in _tweens:
		if tween.is_valid():
			tween.kill()
	_tweens.clear()


func _on_dice_roll_requested(skill_name: String, roll: Dictionary) -> void:
	_play_token += 1
	var token: int = _play_token
	visible = true
	_kill_tweens()
	for i in 3:
		_show_landed(i, IDLE_FACE_VALUE)
	_result_label.text = "%s check" % skill_name
	_continue_button.text = "Roll"
	_continue_button.visible = true
	await _step
	if token != _play_token:
		return

	_continue_button.visible = false
	_result_label.text = "Rolling %s..." % skill_name

	# Each die tumbles until its settle has to start for it to land on
	# time, then plays the settle sheet for the face it rolled, ending on
	# that face's landed still. Random loop phases, so no two dice show
	# the same tumble frame at once.
	var settle_time: float = SETTLE_FRAMES / FPS
	for i in 3:
		var face_value: int = roll.dice[i]
		var tumble_time: float = maxf(TUMBLE_DURATION + i * STAGGER_STEP - settle_time, 0.0)
		var tween: Tween = create_tween()
		tween.tween_method(_show_tumble.bind(i, randi() % TUMBLE_FRAMES), 0.0, tumble_time * FPS, tumble_time)
		tween.tween_method(_show_settle.bind(i, face_value), 0.0, float(SETTLE_FRAMES), settle_time)
		tween.tween_callback(_show_landed.bind(i, face_value))
		_tweens.append(tween)

	# The last die lands last, so its tween finishing means all three are
	# down. Waited on through _step, which _forget also emits, so a roll
	# abandoned mid-tumble (its tweens killed) still wakes up and leaves.
	_tweens[-1].finished.connect(_step.emit)
	await _step
	if token != _play_token:
		return
	_tweens.clear()

	var verdict: String = "Failed"
	if roll.critical_success:
		verdict = "Critical success!"
	elif roll.critical_failure:
		verdict = "Critical failure!"
	elif roll.success:
		verdict = "Success"
	_result_label.text = "%s — %d vs %d" % [verdict, roll.roll, roll.target]

	_continue_button.text = "Continue"
	_continue_button.visible = true
	await _step
	if token != _play_token:
		return
	visible = false
