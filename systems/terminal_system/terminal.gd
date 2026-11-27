class_name Terminal
extends InteractableProp
## A diegetic computer terminal: a prop whose screen is a live 2D page
## (TerminalScreen, drawn into a SubViewport and put on the glass through
## crt_screen.gdshader). "Use" (UseTerminalInteraction) glides the view
## into the screen and types the page out; Escape glides back out.
##
## While the player is at one, GameMode reports TERMINAL (it reads
## Terminal.active), which takes the tactical camera and world clicks away
## the same way a stash or a conversation does, and keeps other modal
## screens from opening (GameMode.input_is_taken).
##
## Scene setup: terminal.tscn. The ViewPoint marker is where the view
## ends up, looking down its -Z at the glass. Screen/ScreenLight is the
## green spill the tube throws on the desk, the hero and the walls: a spot
## sat just behind the glass and facing out, so it lights the room in
## front but not the glass itself or the case around it (every face of
## those has the light behind it). Shadows are off; the target PC is
## low-mid end. It rides on Screen, so moving Screen onto another monitor
## model takes the light along.

## The terminal the player is at, or null. Static so GameMode can ask
## without an autoload; there is only ever one player at one screen.
static var active: Terminal = null

@export var header: String = "TERMINAL"
## The page, in BBCode.
@export_multiline var text: String = ""
## Shown on the glass when nobody is using it.
@export var idle_text: String = "> READY_"
## The page's typeface (see TerminalScreen.Face).
@export var face: TerminalScreen.Face = TerminalScreen.Face.DOT_GOTHIC
@export var view_fov: float = 40.0
@export var glide_time: float = 0.7
## The ScreenLight's energy with the idle prompt up and with a page up.
## The idle screen is mostly black, so it throws little light.
@export var light_idle: float = 0.3
@export var light_in_use: float = 1.0

## How deep the tube's flicker dips (a fraction of full brightness).
const FLICKER := 0.03
## Flicker rate, in radians per second (about 7.5 Hz).
const FLICKER_RATE := 47.0
## How fast the light ramps (linearly) between idle and in use (1/s).
const LIGHT_EASE := 4.0

@onready var _viewport: SubViewport = $ScreenViewport
@onready var _page: TerminalScreen = $ScreenViewport/TerminalScreen
@onready var _view_point: Marker3D = $ViewPoint
@onready var _glass: MeshInstance3D = $Screen
@onready var _light: Light3D = $Screen/ScreenLight

var _glass_material: ShaderMaterial = null
var _light_level := 0.0
var _flicker_time := 0.0
var _camera: Camera3D = null
var _came_from: Camera3D = null
var _overlay: UIScreen = null
var _leaving := false
var _tween: Tween = null
var _on_combat := _on_combat_started


func _ready() -> void:
	# Each terminal draws its own page: the scene's material is shared by
	# every instance, so the glass gets a copy of it.
	_glass_material = (_glass.get_active_material(0) as ShaderMaterial).duplicate() as ShaderMaterial
	_glass_material.set_shader_parameter("screen_tex", _viewport.get_texture())
	_glass_material.set_shader_parameter("design_lines", TerminalScreen.DESIGN_HEIGHT)
	_glass.material_override = _glass_material
	_page.set_face(face)
	# The page moves its scroll in its own _process and this one reads it;
	# as the parent, this would run first and hand the glass last frame's.
	_page.process_priority = process_priority - 1
	_light_level = light_idle
	# Instances start out of step, so a room of terminals doesn't pulse as one.
	_flicker_time = randf() * TAU
	_show_idle()


## The flicker is worked out here rather than in the shader so the same
## number dims the glass and the ScreenLight: the room's green spill
## flickers exactly with the tube.
func _process(delta: float) -> void:
	_flicker_time = fmod(_flicker_time + delta * FLICKER_RATE, TAU)
	var gain := 1.0 - FLICKER * (0.5 + 0.5 * sin(_flicker_time))
	var target := light_in_use if active == self else light_idle
	_light_level = move_toward(_light_level, target, absf(light_in_use - light_idle) * LIGHT_EASE * delta)
	_light.light_energy = _light_level * gain
	_glass_material.set_shader_parameter("glow_gain", gain)
	_glass_material.set_shader_parameter("scroll_velocity", _page.scroll_velocity)
	_glass_material.set_shader_parameter("scroll_rect", _page.scroll_area())


## Whether the player can sit down at this screen right now. UIStack is
## asked too: a menu opened while the hero was still walking up wins.
func can_use() -> bool:
	return active == null and GameMode.current_mode() == GameMode.Mode.EXPLORATION \
			and UIStack.can_open()


func use() -> void:
	if not can_use():
		return
	active = self
	_came_from = get_viewport().get_camera_3d()
	_camera = Camera3D.new()
	_camera.name = "TerminalView"
	_camera.near = 0.03
	add_child(_camera)
	if _came_from:
		_camera.global_transform = _came_from.global_transform
		_camera.fov = _came_from.fov
	CameraDirector.activate_cinematic_camera(_camera)
	# A fight that starts while the player is reading pulls them out.
	if not CombatManager.combat_started.is_connected(_on_combat):
		CombatManager.combat_started.connect(_on_combat)
	_open_overlay()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_page.show_page(header, "")
	_tween = _glide(_view_point.global_transform, view_fov)
	_tween.finished.connect(func():
		if active == self and not _leaving:
			_page.show_page(header, text))


## combat_started is relayed for every encounter, watched or not; only a
## fight in this terminal's own world pulls the player away.
func _on_combat_started(turn_order: Array[Unit]) -> void:
	if not turn_order.is_empty() and turn_order[0].get_world_3d() == get_world_3d():
		step_away()


## Glides back out to the camera the player came from and hands it back.
func step_away() -> void:
	if active != self or _leaving:
		return
	_leaving = true
	if _tween:
		_tween.kill()
	if _overlay and UIStack.is_open(_overlay):
		UIStack.pop(_overlay)
	if is_instance_valid(_came_from) and is_instance_valid(_camera):
		_tween = _glide(_came_from.global_transform, _came_from.fov)
		_tween.finished.connect(_release)
	else:
		_release()


## Moves the view in a straight line while it keeps looking at the glass,
## so the screen stays in frame the whole way. Blending the two end
## rotations directly would point a top-down camera at the horizon halfway
## through. Near each end the rotation eases into that end's own.
func _glide(to: Transform3D, fov: float) -> Tween:
	var from := _camera.global_transform
	var from_fov := _camera.fov
	var tween := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_method(_glide_step.bind(from, to, from_fov, fov), 0.0, 1.0, glide_time)
	return tween


func _glide_step(weight: float, from: Transform3D, to: Transform3D, from_fov: float, to_fov: float) -> void:
	if not is_instance_valid(_camera):
		return
	var at := from.origin.lerp(to.origin, weight)
	var rotation := from.basis.get_rotation_quaternion().slerp(
			to.basis.get_rotation_quaternion(), weight)
	var to_glass := _glass.global_position - at
	if to_glass.length() > 0.01:
		# Straight down at the glass has no "up" to keep; any level one will do.
		var up := Vector3.UP if absf(to_glass.normalized().y) < 0.99 else Vector3.FORWARD
		var facing := Basis.looking_at(to_glass, up).get_rotation_quaternion()
		rotation = from.basis.get_rotation_quaternion().slerp(facing, smoothstep(0.0, 0.4, weight))
		rotation = rotation.slerp(to.basis.get_rotation_quaternion(), smoothstep(0.6, 1.0, weight))
	_camera.global_transform = Transform3D(Basis(rotation), at)
	_camera.fov = lerpf(from_fov, to_fov, weight)


func _release() -> void:
	if _tween:
		_tween.kill()
	_tween = null
	if CombatManager.combat_started.is_connected(_on_combat):
		CombatManager.combat_started.disconnect(_on_combat)
	if is_instance_valid(_camera):
		if _camera.current:
			CameraDirector.deactivate_cinematic_camera()
		_camera.queue_free()
	_camera = null
	_came_from = null
	_leaving = false
	if active == self:
		active = null
	_show_idle()


## The idle page is drawn once and then left alone; the viewport only
## redraws every frame while someone is at the screen.
func _show_idle() -> void:
	_page.show_page(header, idle_text)
	_page.finish_typing()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


# A screen on UIStack while the player is at the terminal: it takes the HUD
# down, and Escape popping it (UIStack's own cancel handling) walks away.
func _open_overlay() -> void:
	if _overlay == null:
		var layer := CanvasLayer.new()
		add_child(layer)
		_overlay = UIScreen.new()
		_overlay.name = "TerminalOverlay"
		_overlay.hides_hud = true
		_overlay.blocks_input_below = true
		_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_overlay.visible = false
		layer.add_child(_overlay)
		_overlay.visibility_changed.connect(func():
			if not _overlay.visible:
				step_away())
	UIStack.push(_overlay)


func _unhandled_input(event: InputEvent) -> void:
	if active != self:
		return
	if _leaving:
		# Still gliding out: Escape belongs to the terminal until it is done,
		# not to whatever menu would open under it.
		if event.is_action_pressed("ui_cancel"):
			get_viewport().set_input_as_handled()
		return
	var handled := true
	if event.is_action_pressed("ui_cancel"):
		step_away()
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP: _page.scroll(-1.0)
			MOUSE_BUTTON_WHEEL_DOWN: _page.scroll(1.0)
			MOUSE_BUTTON_LEFT: _page.finish_typing()
			_: handled = false
	elif event.is_action_pressed("ui_up", true):
		_page.scroll(-1.0)
	elif event.is_action_pressed("ui_down", true):
		_page.scroll(1.0)
	elif event.is_action_pressed("ui_page_up"):
		_page.scroll(-8.0)
	elif event.is_action_pressed("ui_page_down"):
		_page.scroll(8.0)
	else:
		handled = false
	# Handled inside the world's SubViewport is handled at the root too
	# (the container passes the flag up), so UIStack never also opens the
	# esc menu on the Escape that just stepped away; terminal_demo checks it.
	if handled:
		get_viewport().set_input_as_handled()


func _exit_tree() -> void:
	if CombatManager.combat_started.is_connected(_on_combat):
		CombatManager.combat_started.disconnect(_on_combat)
	if active == self:
		active = null
		if _overlay and UIStack.is_open(_overlay):
			UIStack.pop(_overlay)
		if is_instance_valid(_camera) and _camera.current:
			CameraDirector.deactivate_cinematic_camera()
