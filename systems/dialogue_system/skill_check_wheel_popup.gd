extends Control
## Spins the odds wheel for a dialogue skill check, landing on the total
## SuccessRoll.roll_vs() already rolled. A check asks for it with
## Conversation.show(&"dice", {skill, roll}), which parks the choice until
## this calls Conversation.complete(). The roll is fully decided before
## this ever runs; this only plays back an already-final result.
##
## Flow: idle shows the wheel coloured for this check and a Roll button.
## Roll spins it clockwise to the rolled total, then the wheel shows the
## total in its hub, fades the wedges that didn't come up, and the verdict
## line reads out. A click on the card skips the spin; Continue completes
## the wait.
##
## Hidden by default. MainRoot.tscn adds exactly one of these as a
## CanvasLayer child, after DialogueOverlay/ConversationLog so it renders
## on top of both while a roll is in progress.

const OddsWheel = preload("res://systems/dialogue_system/odds_wheel.gd")

const SPIN_TIME: float = 2.8
const SPIN_TURNS_MIN: int = 3
const SPIN_TURNS_MAX: int = 5
const DIM_TIME: float = 0.25
## How far across the winning wedge the needle may stop. Past the wedge's
## first stretch, so the needle is never left bent at rest, and short of
## its far edge, so it's plain which wedge came up.
const LAND_FRACTION_MIN: float = 0.5
const LAND_FRACTION_MAX: float = 0.88

const CARD_BG: Color = Color(0.085, 0.08, 0.074, 0.9)
const TEXT: Color = Color(0.93, 0.9, 0.84)
const CARD_MARGIN: float = 14.0
const COLUMN_SEPARATION: int = 8
const BUTTON_WIDTH: float = 120.0
const RESULT_FONT_SIZE: int = 18
## Centred in the screen above the conversation band: the room the
## content-sized band needs at the bottom, plus a gap.
const _BAND_CLEARANCE: float = 170.0

var _conversation: Conversation = null
var _played_serial: int = -1
## Bumped whenever a roll starts or is abandoned; a roll still awaiting
## with an old token gives up.
var _play_token: int = 0
## The spin is playing, so a click on the card skips it.
var _animating: bool = false
var _tweens: Array[Tween] = []

var _card: PanelContainer
var _wheel: OddsWheel
var _result_label: Label
var _continue_button: Button

## The roll's next stage may go: the Roll or Continue button, the spin
## ending, a skip, or the roll being abandoned.
signal _step


func _ready() -> void:
	visible = false
	_build_scene()
	Conversations.follow(self, _on_conversation_began)


func _exit_tree() -> void:
	_forget()


func _on_conversation_began(c: Conversation) -> void:
	_forget()
	_conversation = c
	_played_serial = -1
	c.attach(&"dice", self)
	c.changed.connect(_on_changed)
	_on_changed()


func _on_changed() -> void:
	var c: Conversation = _conversation
	if c == null:
		return
	if c.ended:
		_forget()
		return
	if visible and c.waiting.get("serial") != _played_serial:
		_abandon_roll()
	if c.waiting.get("kind") != &"dice" or c.waiting.serial == _played_serial:
		return
	var serial: int = c.waiting.serial
	_played_serial = serial
	var data: Dictionary = c.waiting.data
	await _on_dice_roll_requested(data.skill, data.roll)
	if c == _conversation and c.waiting.get("serial") == serial:
		c.complete()


func _forget() -> void:
	if _conversation != null:
		_conversation.detach(&"dice", self)
		if _conversation.changed.is_connected(_on_changed):
			_conversation.changed.disconnect(_on_changed)
		_conversation = null
	_abandon_roll()


func _abandon_roll() -> void:
	_play_token += 1
	_animating = false
	_kill_tweens()
	visible = false
	if _continue_button != null:
		_continue_button.visible = false
	_step.emit()


func _on_dice_roll_requested(skill_name: String, roll: Dictionary) -> void:
	_play_token += 1
	var token: int = _play_token
	visible = true
	_animating = false
	_kill_tweens()

	_wheel.show_odds(roll.target)
	_result_label.text = "%s check" % skill_name
	_result_label.add_theme_color_override("font_color", TEXT)
	_continue_button.text = "Roll"
	_continue_button.visible = true
	await _step
	if token != _play_token:
		return

	_continue_button.visible = false
	_result_label.text = "Rolling %s..." % skill_name
	_animating = true
	var landing: float = _wheel.spin_to_land_on(
		roll.roll,
		randf_range(LAND_FRACTION_MIN, LAND_FRACTION_MAX),
		randi_range(SPIN_TURNS_MIN, SPIN_TURNS_MAX))
	var spin_tween: Tween = _new_tween()
	spin_tween.tween_property(_wheel, "spin", landing, SPIN_TIME) \
		.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	spin_tween.finished.connect(_step.emit)
	await _step
	if token != _play_token:
		return

	_animating = false
	_kill_tweens()
	_wheel.spin = landing
	_wheel.land_on(roll.roll)
	_result_label.add_theme_color_override("font_color", _wheel.ink_of(roll.roll))
	_result_label.text = _verdict_text(roll)
	_new_tween().tween_property(_wheel, "dim", 1.0, DIM_TIME)
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


func _new_tween() -> Tween:
	var tween: Tween = create_tween()
	_tweens.append(tween)
	return tween


func _kill_tweens() -> void:
	for tween in _tweens:
		if tween != null and tween.is_valid():
			tween.kill()
	_tweens.clear()


static func _verdict_text(roll: Dictionary) -> String:
	var word: String = "Success" if roll.success else "Failure"
	if roll.critical_success or roll.critical_failure:
		word = "Critical " + word
	var margin: int = roll.target - roll.roll if roll.success else roll.roll - roll.target
	if margin > 0:
		word += " by %d" % margin
	return "%s — %d vs %d" % [word, roll.roll, roll.target]


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
	_card.add_theme_stylebox_override("panel", _box(CARD_BG, CARD_MARGIN))
	_card.gui_input.connect(_on_card_gui_input)

	var column := VBoxContainer.new()
	_card.add_child(column)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", COLUMN_SEPARATION)

	_wheel = OddsWheel.new()
	column.add_child(_wheel)
	_wheel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	_result_label = _label(column, RESULT_FONT_SIZE, TEXT)
	_result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_result_label.custom_minimum_size.x = _wheel.custom_minimum_size.x
	# One line always reserved, so the card doesn't jump as the text changes.
	_result_label.custom_minimum_size.y = _result_label.get_line_height()

	var button_holder := CenterContainer.new()
	column.add_child(button_holder)
	button_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_continue_button = Button.new()
	button_holder.add_child(_continue_button)
	_continue_button.custom_minimum_size.x = BUTTON_WIDTH
	_continue_button.text = "Continue"
	# The holder keeps the button's room while it's hidden, so the card
	# holds its size through the spin.
	button_holder.custom_minimum_size = _continue_button.get_combined_minimum_size()
	_continue_button.visible = false
	_continue_button.pressed.connect(_step.emit)


static func _box(bg: Color, margin: float) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.set_corner_radius_all(10)
	box.set_content_margin_all(margin)
	return box


static func _label(parent: Control, font_size: int, colour: Color) -> Label:
	var label := Label.new()
	parent.add_child(label)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", colour)
	return label
