extends Node2D
## Standalone prototype — the REAL node type this project would use
## once actual rendered dice frames exist (AnimatedSprite2D +
## SpriteFrames), fed placeholder frames generated procedurally
## (assets/dice_placeholder/) since real ones need an actual Blender
## render pass, not something buildable in code. Proves the BG3
## architecture confirmed via the "Dice Sprites Generator" mod page
## (nexusmods.com/baldursgate3/mods/1325): the tumble animation ALWAYS
## plays the same way regardless of the roll — the actual result is a
## fully separate Label overlay, decided before the animation even
## starts, never read back from wherever the sprite lands. Run this
## scene directly (F6) and press Roll.
##
## Compare against dice_roll_prototype.tscn (the live-3D version) —
## same "decide first, animate second" principle, different renderer.
## This one's the direction actually chosen: 2D sprite flipbook.

const FRAME_DIR: String = "res://assets/dice_placeholder/"
const TUMBLE_FRAME_COUNT: int = 9
const TUMBLE_FPS: float = 12.0

var _sprite: AnimatedSprite2D
var _result_label: Label
var _rolling: bool = false
var _pending_result: int = 1


func _ready() -> void:
	_build_scene()


func _build_scene() -> void:
	var frames := SpriteFrames.new()
	frames.remove_animation("default")

	frames.add_animation("tumble")
	frames.set_animation_loop("tumble", false)
	frames.set_animation_speed("tumble", TUMBLE_FPS)
	for i in TUMBLE_FRAME_COUNT:
		var path: String = "%sdice_tumble_%02d.png" % [FRAME_DIR, i]
		frames.add_frame("tumble", load(path))

	frames.add_animation("static")
	frames.set_animation_loop("static", false)
	frames.add_frame("static", load(FRAME_DIR + "dice_static.png"))

	_sprite = AnimatedSprite2D.new()
	add_child(_sprite)
	_sprite.sprite_frames = frames
	_sprite.animation = "static"
	_sprite.position = Vector2(160, 140)
	_sprite.scale = Vector2(1.5, 1.5)
	_sprite.animation_finished.connect(_on_tumble_finished)

	var roll_button := Button.new()
	add_child(roll_button)
	roll_button.text = "Roll"
	roll_button.position = Vector2(20, 260)
	roll_button.pressed.connect(_roll)

	_result_label = Label.new()
	add_child(_result_label)
	_result_label.position = Vector2(120, 262)
	_result_label.add_theme_font_size_override("font_size", 24)
	_result_label.text = "Press Roll"


func _roll() -> void:
	if _rolling:
		return
	_rolling = true

	# Decided FIRST, same as the 3D prototype — the sprite animation
	# plays completely on its own; it never gets consulted for what
	# the "real" answer is.
	_pending_result = randi_range(1, 6)
	_result_label.text = "Rolling..."
	_sprite.play("tumble")


func _on_tumble_finished() -> void:
	_sprite.animation = "static"
	_result_label.text = "Result: %d" % _pending_result
	_rolling = false
