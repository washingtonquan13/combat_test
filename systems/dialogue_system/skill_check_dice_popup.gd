extends Control
## Shows a 3d6 tumble for a dialogue skill check, landing on the exact
## faces SuccessRoll.roll_vs() already rolled — a check asks for it with
## Conversation.show(&"dice", {skill, roll}), which parks the choice until
## this calls Conversation.complete(). The roll is fully decided before
## this ever runs; this only plays back an already-final result.
##
## BG3-style sprite dice, no 3D in game: every die is a TextureRect whose
## AtlasTexture steps through pre-rendered sheets in assets/ui/dice/ —
## a result-agnostic motion-blurred roll (a different one per die, so the
## three never move in unison), then the settle sheet for the face that
## die rolled (it wobbles to rest with that face square to the camera),
## then the landed still. The sheets come from the community BG3 custom
## dice rig, d20 swapped for a cube: tools/dice/render_d6_sheets.py
## renders them in Blender and tools/dice/pack_d6_sheets.py packs them
## (tools/dice/build.sh runs both); the frame size, grid width, rate and
## frame counts below must match those scripts.
##
## Hidden by default. MainRoot.tscn adds exactly one of these as a
## CanvasLayer child, after DialogueOverlay/ConversationLog so it
## renders on top of both while a roll is in progress.

const FRAME_PX: int = 256
## The rig's own frame rate; every sheet is played at it.
const FPS: float = 18.0
## Every sheet is this many frames wide, row-major.
const COLS: int = 8
## Die i plays ROLL_SHEETS[i] once; ROLL_FRAMES[i] is its frame count.
const ROLL_SHEETS: Array[Texture2D] = [
	preload("res://assets/ui/dice/d6_roll_double_roll_1.png"),
	preload("res://assets/ui/dice/d6_roll_double_roll_2.png"),
	preload("res://assets/ui/dice/d6_roll_single_roll.png"),
]
const ROLL_FRAMES: Array[int] = [27, 28, 61]
## Index = face value - 1.
const SETTLE_SHEETS: Array[Texture2D] = [
	preload("res://assets/ui/dice/d6_settle_1.png"),
	preload("res://assets/ui/dice/d6_settle_2.png"),
	preload("res://assets/ui/dice/d6_settle_3.png"),
	preload("res://assets/ui/dice/d6_settle_4.png"),
	preload("res://assets/ui/dice/d6_settle_5.png"),
	preload("res://assets/ui/dice/d6_settle_6.png"),
]
const SETTLE_FRAMES: int = 18
## One row, faces 1..6 left to right.
const LANDED_SHEET: Texture2D = preload("res://assets/ui/dice/d6_landed.png")

## On-screen size of one frame. Face-on, the die fills 57% of it; the
## rest is room for its corners mid-roll and the blur smear.
const DIE_DISPLAY_PX: float = 150.0
## Neighbouring frames overlap by this much, since their edges are empty
## once the die is at rest.
const DIE_OVERLAP_PX: float = 50.0
## Each die starts rolling this much after the previous one.
const STAGGER_STEP: float = 0.25
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
const _CORNER_HEIGHT: float = 220.0
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


func _show_frame(die: int, sheet: Texture2D, index: int) -> void:
	var face: AtlasTexture = _faces[die]
	face.atlas = sheet
	face.region = Rect2((index % COLS) * FRAME_PX, floori(float(index) / COLS) * FRAME_PX, FRAME_PX, FRAME_PX)


func _show_roll(frame: float, die: int) -> void:
	_show_frame(die, ROLL_SHEETS[die], mini(int(frame), ROLL_FRAMES[die] - 1))


func _show_settle(frame: float, die: int, face_value: int) -> void:
	_show_frame(die, SETTLE_SHEETS[face_value - 1], mini(int(frame), SETTLE_FRAMES - 1))


func _show_landed(die: int, face_value: int) -> void:
	_show_frame(die, LANDED_SHEET, face_value - 1)


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

	# Each die waits its stagger, plays its roll once, then the settle
	# sheet for the face it rolled, ending on that face's landed still.
	var settle_time: float = SETTLE_FRAMES / FPS
	var last_down: float = -1.0
	var last: Tween = null
	for i in 3:
		var face_value: int = roll.dice[i]
		var roll_time: float = ROLL_FRAMES[i] / FPS
		var tween: Tween = create_tween()
		tween.tween_callback(_show_roll.bind(0.0, i))
		tween.tween_interval(i * STAGGER_STEP)
		tween.tween_method(_show_roll.bind(i), 0.0, float(ROLL_FRAMES[i]), roll_time)
		tween.tween_method(_show_settle.bind(i, face_value), 0.0, float(SETTLE_FRAMES), settle_time)
		tween.tween_callback(_show_landed.bind(i, face_value))
		_tweens.append(tween)
		var down: float = i * STAGGER_STEP + roll_time + settle_time
		if down > last_down:
			last_down = down
			last = tween

	# Waited on through _step, which _forget also emits, so a roll
	# abandoned mid-tumble (its tweens killed) still wakes up and leaves.
	last.finished.connect(_step.emit)
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
