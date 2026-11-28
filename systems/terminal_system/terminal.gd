class_name Terminal
extends InteractableProp
## A diegetic computer terminal: a prop whose screen is a live 2D page
## (TerminalScreen, drawn into a SubViewport and put on the glass through
## crt_screen.gdshader). "Use" (UseTerminalInteraction) cuts the view
## to the screen and types out its menu (TerminalMenu), which works like
## a Fallout terminal's: Up/Down or the mouse moves the highlight, Enter or
## a click opens the entry, Tab (or a right click) goes back a level and
## logs off from the top. Escape logs off from anywhere.
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
## What the screen offers. An exam entry runs the exam (TerminalExam):
## the answers are menu lines, and A-I / 1-9 pick one too. Logging off or
## going back mid-exam voids the attempt.
@export var menu: TerminalMenu = null
## Shown on the glass when nobody is using it.
@export var idle_text: String = "> READY_"
## The page's typeface (see TerminalScreen.Face).
@export var face: TerminalScreen.Face = TerminalScreen.Face.DOT_GOTHIC
@export var view_fov: float = 40.0
## The ScreenLight's energy with the idle prompt up and with a page up.
## The idle screen is mostly black, so it throws little light.
@export var light_idle: float = 0.3
@export var light_in_use: float = 1.0

## How deep the tube's flicker dips (a fraction of full brightness).
const FLICKER := 0.03
## Flicker rate, in radians per second (about 7.5 Hz).
const FLICKER_RATE := 47.0
## The tube's disturbances. Timings and strengths follow Fallout 4's
## [Pipboy] INI defaults (flicker every 15-25 s for 0.1-0.6 s, burst 1.0 /
## 0.25, shudder 0.2, vertical hold 3 rolls at rate 8, a scan line every
## 3-10 s at half a screen a second); how each number maps onto this tube
## is a reading of their names, not a copy of the game's code.
## A flicker dip: how often, how long, how deep, and how fast it stutters.
const DIP_EVERY := Vector2(15.0, 25.0)
const DIP_LENGTH := Vector2(0.1, 0.6)
const DIP_DEPTH := 0.1
const DIP_RATE := 22.0 * TAU
## A burst flashes the picture when it changes: held a moment, then
## fading by this factor per second.
const BURST_LARGE := 1.0
const BURST_SMALL := 0.25
const BURST_HOLD := 0.06
const BURST_FADE := 6.0
const SHUDDER := 0.2
const SHUDDER_TIME := 0.25
## Vertical hold: the picture slips on log-in and slows into lock. Kept to
## one roll at a few a second: the game's 3 at rate 8 sweeps the blanking
## bar over the whole view about 8 times a second, a strobe.
const VHOLD_ROLLS := 1.0
const VHOLD_RATE := 2.5
const SCAN_EVERY := Vector2(3.0, 10.0)
const SCAN_SPEED := 0.5
## A slow breathing of the whole tube.
const PULSE := 0.04
const PULSE_RATE := 0.5 * TAU
## How fast the light ramps (linearly) between idle and in use (1/s).
const LIGHT_EASE := 4.0
## The line under a page that goes back up.
const RETURN_LINE := "[RETURN]"
const GLOW_SHADER := preload("res://systems/terminal_system/terminal_glow.gdshader")

@onready var _viewport: SubViewport = $ScreenViewport
@onready var _page: TerminalScreen = $ScreenViewport/TerminalScreen
@onready var _view_point: Marker3D = $ViewPoint
@onready var _glass: MeshInstance3D = $Screen
@onready var _light: Light3D = $Screen/ScreenLight

var _glass_material: ShaderMaterial = null
## The page blurred at a quarter of its resolution: the glass's glow.
var _glow_viewport: SubViewport = null
var _light_level := 0.0
var _flicker_time := 0.0
var _pulse_time := 0.0
var _dip_in := 0.0
## The dip's own stutter phase, apart from the flicker's: their rates
## aren't whole multiples, so one phase can't drive both.
var _dip_time := 0.0
var _dip_left := 0.0
var _burst := 0.0
var _burst_hold := 0.0
var _shudder_left := 0.0
## Rolls of the vertical hold still to go (counts down to 0).
var _vhold_left := 0.0
var _scan_in := 0.0
var _scan_at := -1.0
var _camera: Camera3D = null
var _came_from: Camera3D = null
var _overlay: UIScreen = null
var _leaving := false
var _exam_run: TerminalExamRun = null
## Where the player is in the menus: each level is {menu, selected} for a
## menu, {entry, run} for an open page or exam. The last is on screen.
var _levels: Array[Dictionary] = []
var _on_combat := _on_combat_started
## Units hidden because they stand where the view comes in; shown again on
## release.
var _hidden: Array[Node3D] = []

## How near (m, across the floor) to the view's path a unit must stand to
## be hidden: the hero walks up to the screen and would fill the shot.
const HIDE_RADIUS := 0.9


func _ready() -> void:
	# Each terminal draws its own page: the scene's material is shared by
	# every instance, so the glass gets a copy of it.
	_glass_material = (_glass.get_active_material(0) as ShaderMaterial).duplicate() as ShaderMaterial
	_glass_material.set_shader_parameter("screen_tex", _viewport.get_texture())
	_glass_material.set_shader_parameter("glow_tex", _make_glow())
	_glass_material.set_shader_parameter("design_lines", TerminalScreen.DESIGN_HEIGHT)
	_glass.material_override = _glass_material
	_page.set_face(face)
	# The page moves its scroll in its own _process and this one reads it;
	# as the parent, this would run first and hand the glass last frame's.
	_page.process_priority = process_priority - 1
	_light_level = light_idle
	# Instances start out of step, so a room of terminals doesn't pulse as one.
	_flicker_time = randf() * TAU
	_pulse_time = randf() * TAU
	_dip_in = randf_range(DIP_EVERY.x, DIP_EVERY.y)
	_scan_in = randf_range(SCAN_EVERY.x, SCAN_EVERY.y)
	_show_idle()


## Builds the GlowViewport after ScreenViewport, so it blurs this frame's
## page rather than last frame's.
func _make_glow() -> Texture2D:
	_glow_viewport = SubViewport.new()
	_glow_viewport.name = "GlowViewport"
	_glow_viewport.disable_3d = true
	_glow_viewport.size = _viewport.size / 4
	var blur := ColorRect.new()
	blur.set_anchors_preset(Control.PRESET_FULL_RECT)
	var material := ShaderMaterial.new()
	material.shader = GLOW_SHADER
	material.set_shader_parameter("page_tex", _viewport.get_texture())
	blur.material = material
	_glow_viewport.add_child(blur)
	_viewport.add_sibling(_glow_viewport)
	return _glow_viewport.get_texture()


func _set_redraw(mode: SubViewport.UpdateMode) -> void:
	_viewport.render_target_update_mode = mode
	_glow_viewport.render_target_update_mode = mode


## The flicker is worked out here rather than in the shader so the same
## number dims the glass and the ScreenLight: the room's green spill
## flickers exactly with the tube.
func _process(delta: float) -> void:
	_flicker_time = fmod(_flicker_time + delta * FLICKER_RATE, TAU)
	_pulse_time = fmod(_pulse_time + delta * PULSE_RATE, TAU)
	var gain := 1.0 - FLICKER * (0.5 + 0.5 * sin(_flicker_time)) \
			- PULSE * (0.5 + 0.5 * sin(_pulse_time))
	gain *= _dip(delta)
	if _burst_hold > 0.0:
		_burst_hold -= delta
	else:
		_burst *= exp(-BURST_FADE * delta)
		if _burst < 0.01:
			_burst = 0.0
	_shudder_left = maxf(_shudder_left - delta, 0.0)
	# Slows as it nears lock, so the picture settles rather than stops dead.
	_vhold_left = maxf(_vhold_left - VHOLD_RATE * delta * clampf(_vhold_left * 1.5, 0.15, 1.0), 0.0)
	_advance_scan(delta)
	# The burst is drawn by the shader (only there, so the glass isn't
	# flashed twice); the light gets its share of the flash here.
	_glass_material.set_shader_parameter("burst", _burst)
	_glass_material.set_shader_parameter("shudder", SHUDDER * minf(_shudder_left / SHUDDER_TIME, 1.0))
	_glass_material.set_shader_parameter("vhold", fposmod(_vhold_left, 1.0))
	_glass_material.set_shader_parameter("scan_at", _scan_at)
	# Noise in the shader is seeded from this, not TIME: TIME grows past
	# what its hash can resolve after a few minutes and the noise freezes.
	_glass_material.set_shader_parameter("noise_seed", fmod(Engine.get_process_frames() * 0.618034, 1.0))
	var target := light_in_use if active == self else light_idle
	_light_level = move_toward(_light_level, target, absf(light_in_use - light_idle) * LIGHT_EASE * delta)
	_light.light_energy = _light_level * gain * (1.0 + _burst * 0.6)
	_glass_material.set_shader_parameter("glow_gain", gain)
	_glass_material.set_shader_parameter("scroll_velocity", _page.scroll_velocity)
	_glass_material.set_shader_parameter("scroll_rect", _page.scroll_area())


## The brightness factor of a flicker dip: 1 between dips; during one, a
## fast stutter down to 1 - DIP_DEPTH.
func _dip(delta: float) -> float:
	if _dip_left > 0.0:
		_dip_left -= delta
		if _dip_left <= 0.0:
			_dip_in = randf_range(DIP_EVERY.x, DIP_EVERY.y)
		_dip_time = fmod(_dip_time + DIP_RATE * delta, TAU)
		return 1.0 - DIP_DEPTH * (0.5 + 0.5 * sin(_dip_time))
	_dip_in -= delta
	if _dip_in <= 0.0:
		_dip_left = randf_range(DIP_LENGTH.x, DIP_LENGTH.y)
	return 1.0


func _advance_scan(delta: float) -> void:
	if _scan_at >= 0.0:
		_scan_at += SCAN_SPEED * delta
		if _scan_at > 1.05:
			_scan_at = -1.0
			_scan_in = randf_range(SCAN_EVERY.x, SCAN_EVERY.y)
		return
	_scan_in -= delta
	if _scan_in <= 0.0:
		_scan_at = 0.0


## Kicks the tube: a flash and a shake as the picture changes. rolls > 0
## also slips the vertical hold that many frames.
func disturb(strength: float, rolls: float = 0.0) -> void:
	if strength >= _burst:
		_burst = strength
		_burst_hold = BURST_HOLD
	_shudder_left = SHUDDER_TIME
	_vhold_left = maxf(_vhold_left, rolls)


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
	_camera.global_transform = _view_point.global_transform
	_camera.fov = view_fov
	CameraDirector.activate_cinematic_camera(_camera)
	# A fight that starts while the player is reading pulls them out.
	if not CombatManager.combat_started.is_connected(_on_combat):
		CombatManager.combat_started.connect(_on_combat)
	_open_overlay()
	_set_redraw(SubViewport.UPDATE_ALWAYS)
	_page.show_page(header, "")
	_hide_blockers()
	_show_content()


## Hides the units standing between the glass and where the view comes in
## (the hero, who walked up to use it, and anyone at their shoulder).
func _hide_blockers() -> void:
	var from := _came_from.global_position if _came_from else _view_point.global_position
	var to := _view_point.global_position
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Node3D
		if unit == null or not unit.visible or unit.get_world_3d() != get_world_3d():
			continue
		var at := unit.global_position
		# Nearest point on the floor-plane segment from the glass out to
		# a little behind the view point, toward where the view starts.
		var a := Vector2(_glass.global_position.x, _glass.global_position.z)
		var out := Vector2(to.x, to.z) + (Vector2(from.x, from.z) - Vector2(to.x, to.z)).limit_length(1.0)
		var p := Vector2(at.x, at.z)
		var t := clampf((p - a).dot(out - a) / maxf((out - a).length_squared(), 0.0001), 0.0, 1.0)
		if p.distance_to(a.lerp(out, t)) < HIDE_RADIUS:
			unit.visible = false
			_hidden.append(unit)


func _show_hidden() -> void:
	for unit in _hidden:
		if is_instance_valid(unit):
			unit.visible = true
	_hidden.clear()


func _show_content() -> void:
	_levels = [{"menu": menu, "selected": 0}]
	_show_level()
	disturb(BURST_LARGE, VHOLD_ROLLS)


## Draws the level on top of _levels. Entries a flag hides are worked out
## here, each time, so one set while the player was in a submenu shows up.
func _show_level() -> void:
	var level: Dictionary = _levels.back()
	_exam_run = null
	if level.has("menu"):
		var at: TerminalMenu = level.menu
		var labels := PackedStringArray()
		if at:
			for entry in at.shown_entries():
				labels.append(entry.label)
		var back := "[ESC / TAB] LOG OFF" if _levels.size() == 1 else "[TAB] BACK    [ESC] LOG OFF"
		_page.show_page(header, at.intro if at else "", "[UP/DOWN] SELECT    [ENTER] OPEN    " + back,
				labels, level.selected)
		return
	var entry: TerminalEntry = level.entry
	if entry.exam:
		_exam_run = level.run
		_show_exam_page()
	else:
		_page.show_page(header, entry.page, "[WHEEL / UP / DOWN] SCROLL    [ENTER / TAB] BACK    [ESC] LOG OFF",
				PackedStringArray([RETURN_LINE]))


func _show_exam_page() -> void:
	var choices := _exam_run.choices()
	if choices.is_empty():
		choices.append(RETURN_LINE)
	_page.show_page(header, _exam_run.page_text(), _exam_run.footer(), choices)


## Opens line index: an entry on a menu, an answer on an exam, Return on a
## page. A press while the page is still typing only finishes it.
func _activate(index: int) -> void:
	if _page.finish_typing():
		return
	var level: Dictionary = _levels.back()
	if level.has("menu"):
		var shown: Array[TerminalEntry] = level.menu.shown_entries() if level.menu else []
		if index < 0 or index >= shown.size():
			return
		level.selected = index
		_open(shown[index])
	elif _exam_run and not _exam_run.choices().is_empty():
		if _exam_run.choose(index):
			_show_exam_page()
			disturb(BURST_SMALL)
	else:
		_back()


func _open(entry: TerminalEntry) -> void:
	if not entry.sets_flag.is_empty():
		FlagManager.set_flag(entry.sets_flag)
	if entry.exam:
		_levels.append({"entry": entry, "run": TerminalExamRun.new(entry.exam)})
	elif entry.submenu:
		_levels.append({"menu": entry.submenu, "selected": 0})
	else:
		_levels.append({"entry": entry})
	_show_level()
	disturb(BURST_SMALL)


## Up a level; from the top, logs off.
func _back() -> void:
	if _levels.size() <= 1:
		step_away()
		return
	_levels.pop_back()
	_show_level()
	disturb(BURST_SMALL)


## combat_started is relayed for every encounter, watched or not; only a
## fight in this terminal's own world pulls the player away.
func _on_combat_started(turn_order: Array[Unit]) -> void:
	if not turn_order.is_empty() and turn_order[0].get_world_3d() == get_world_3d():
		step_away()


## Cuts back to the camera the player came from.
func step_away() -> void:
	if active != self or _leaving:
		return
	_leaving = true
	if _overlay and UIStack.is_open(_overlay):
		UIStack.pop(_overlay)
	_release()


func _release() -> void:
	if CombatManager.combat_started.is_connected(_on_combat):
		CombatManager.combat_started.disconnect(_on_combat)
	if is_instance_valid(_camera):
		if _camera.current:
			CameraDirector.deactivate_cinematic_camera()
		_camera.queue_free()
	_camera = null
	_came_from = null
	_exam_run = null
	_levels.clear()
	_show_hidden()
	_leaving = false
	if active == self:
		active = null
	_show_idle()


## The idle page is drawn once and then left alone; the viewport only
## redraws every frame while someone is at the screen.
func _show_idle() -> void:
	_page.show_page(header, idle_text)
	_page.finish_typing()
	_set_redraw(SubViewport.UPDATE_ONCE)


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
	if _exam_run and _exam_key(event):
		get_viewport().set_input_as_handled()
		return
	# Still gliding in: nothing on the glass to pick yet.
	if _levels.is_empty():
		if event.is_action_pressed("ui_cancel"):
			step_away()
			get_viewport().set_input_as_handled()
		return
	var on_page: bool = not _levels.back().has("menu") and _exam_run == null
	var handled := true
	if event.is_action_pressed("ui_cancel"):
		step_away()
	elif event is InputEventMouseMotion:
		var item := _item_under_mouse()
		if item >= 0:
			_page.select(item)
		handled = false
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP: _page.scroll(-1.0)
			MOUSE_BUTTON_WHEEL_DOWN: _page.scroll(1.0)
			MOUSE_BUTTON_LEFT:
				var item := _item_under_mouse()
				if item >= 0:
					_page.select(item)
					_activate(item)
				else:
					_page.finish_typing()
			MOUSE_BUTTON_RIGHT: _back()
			_: handled = false
	elif _is_key(event, [KEY_TAB, KEY_BACKSPACE]):
		_back()
	elif event.is_action_pressed("ui_accept") or _is_key(event, [KEY_KP_ENTER]):
		_activate(_page.selected())
	elif event.is_action_pressed("ui_up", true):
		if on_page:
			_page.scroll(-1.0)
		else:
			_page.select(_page.selected() - 1)
	elif event.is_action_pressed("ui_down", true):
		if on_page:
			_page.scroll(1.0)
		else:
			_page.select(_page.selected() + 1)
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


static func _is_key(event: InputEvent, keys: Array) -> bool:
	var key := event as InputEventKey
	return key != null and key.pressed and not key.echo and key.keycode in keys


## The menu line under the mouse, or -1: the mouse ray meets the glass,
## and the point is bent the way crt_screen.gdshader bends the picture.
func _item_under_mouse() -> int:
	if not is_instance_valid(_camera) or _page.item_count() == 0:
		return -1
	var mouse := get_viewport().get_mouse_position()
	var plane := Plane(_glass.global_basis.z.normalized(), _glass.global_position)
	var hit: Variant = plane.intersects_ray(_camera.project_ray_origin(mouse), _camera.project_ray_normal(mouse))
	if hit == null:
		return -1
	var local: Vector3 = _glass.global_transform.affine_inverse() * (hit as Vector3)
	var quad := (_glass.mesh as QuadMesh).size
	var uv := Vector2(local.x / quad.x + 0.5, 0.5 - local.y / quad.y)
	var curvature: float = _glass_material.get_shader_parameter("curvature")
	var c := uv * 2.0 - Vector2.ONE
	c *= 1.0 + curvature * c.dot(c) * 0.5
	return _page.item_at((c * 0.5 + Vector2(0.5, 0.5)) * Vector2(_viewport.size))


## A letter or number answers the question up (Enter on the highlighted
## line does too, through _activate). A key while the page is still typing
## only finishes it, so an answer is never given to a question the player
## hasn't seen. True if the key was the exam's.
func _exam_key(event: InputEvent) -> bool:
	var key := event as InputEventKey
	# Answers are final, so Ctrl+C or Alt+A must not give one.
	if key == null or not key.pressed or key.echo \
			or key.ctrl_pressed or key.alt_pressed or key.meta_pressed:
		return false
	var choice := -1
	if key.keycode >= KEY_A and key.keycode <= KEY_I:
		choice = key.keycode - KEY_A
	elif key.keycode >= KEY_1 and key.keycode <= KEY_9:
		choice = key.keycode - KEY_1
	elif key.keycode >= KEY_KP_1 and key.keycode <= KEY_KP_9:
		choice = key.keycode - KEY_KP_1
	if choice < 0 or _exam_run.stage != TerminalExamRun.Stage.QUESTION:
		return false
	if _page.finish_typing():
		return true
	if _exam_run.answer(choice):
		_show_exam_page()
		disturb(BURST_SMALL)
	return true


func _exit_tree() -> void:
	if CombatManager.combat_started.is_connected(_on_combat):
		CombatManager.combat_started.disconnect(_on_combat)
	if active == self:
		active = null
		if _overlay and UIStack.is_open(_overlay):
			UIStack.pop(_overlay)
		if is_instance_valid(_camera) and _camera.current:
			CameraDirector.deactivate_cinematic_camera()
