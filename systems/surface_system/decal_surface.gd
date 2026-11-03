class_name DecalSurface
extends Decal
## A surface drawn on the ground: Grease, Water, Ice, Blood... the film
## over one SurfacePatch's cells. A Decal, so it drapes over steps and
## slopes. A Decal can't run a shader, so `film` (a canvas_item shader
## built on film_passes.gdshaderinc) draws its albedo, normal map and,
## when it `glows`, emission in small SubViewports, redrawn only while
## the cells change. A glow can also move: once settled, `glow_frames`
## pictures of it are drawn and then played on a loop, so it animates
## without redrawing. A Decal doesn't show a ViewportTexture, so each
## redraw is copied into an ImageTexture.
##
## SurfaceManager hands it cells: show_cells() spreads new ones out from
## where they were cast, recede_cells() thins some away, set_cells() swaps
## the set at once, dissipate() recedes the lot. The shader reads the
## cells as a mask texture, one texel per cell, so a merged patch draws as
## one pool. The mask is flat: a cell paints every floor inside the
## decal's box above and below it. Units wear Unit.RENDER_LAYER, which
## cull_mask leaves out, so the film paints the floor and not their feet.

## After each new picture of the film is in the decal's textures: what
## a film merged into this one waits for before it frees itself.
signal drawn

## Cells of padding round the mask, room for the outline to wander out.
const PAD: int = 2
## How far a decal reaches above and below its cells' floors.
const REACH_Y: float = 1.2

## The look, edited in the inspector; each pass draws a copy of it.
@export var film: ShaderMaterial
## Also draw the film's emission pass, into texture_emission.
@export var glows: bool = false
## Pixels drawn per meter of film, and the most along either side.
@export var pixels_per_meter: float = 64.0
@export var max_resolution: int = 1024
@export var spread_seconds: float = 0.6
@export var recede_seconds: float = 1.5
## When it glows: how many pictures of the glow to draw once it has
## settled, looped at glow_fps (the shader loops on glow_phase). 0 holds
## the glow still.
@export var glow_frames: int = 0
@export var glow_fps: float = 10.0
## Low: the film is glossy, so it catches the scene's lights.
@export var roughness: float = 0.12

var _materials: Array[ShaderMaterial] = []
var _viewports: Array[SubViewport] = []
var _canvases: Array[ColorRect] = []
var _textures: Array[ImageTexture] = []
var _mask: ImageTexture
var _copy_pending: bool = false
var _glow_loop: Array[ImageTexture] = []
## Which glow picture is being drawn; -1 while none is.
var _glow_drawing: int = -1
## Cells shown, by key; dying ones stay until they've receded.
var _live: Dictionary[Vector2i, SurfaceCell] = {}
## When each cell starts arriving / receding, in seconds.
var _arrive: Dictionary[Vector2i, float] = {}
var _dying: Dictionary[Vector2i, float] = {}
## Redraw next frame even though nothing animates.
var _dirty: bool = false
var _shown: bool = false
## The box of the mask last drawn, applied with its picture, and its
## cells for _cells_shown() when they changed.
var _box_centre: Vector3
var _box_size: Vector3
var _box_cells: Array[SurfaceCell] = []
var _box_pending: bool = false
## The cell set changed since _cells_shown() last saw it.
var _cells_dirty: bool = false


func _ready() -> void:
	for film_pass in ([0, 1, 2] if glows else [0, 1]):
		var viewport := SubViewport.new()
		viewport.size = Vector2i(4, 4)
		viewport.disable_3d = true
		viewport.transparent_bg = true
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		var canvas := ColorRect.new()
		var material := film.duplicate() as ShaderMaterial
		material.set_shader_parameter("film_pass", film_pass)
		canvas.material = material
		viewport.add_child(canvas)
		add_child(viewport)
		_viewports.append(viewport)
		_canvases.append(canvas)
		_materials.append(material)
	for _viewport in _viewports:
		var blank := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		_textures.append(ImageTexture.create_from_image(blank))
	_show_textures()
	RenderingServer.frame_post_draw.connect(_copy_drawn)
	var orm := Image.create(4, 4, false, Image.FORMAT_RGB8)
	orm.fill(Color(1.0, roughness, 0.0))
	texture_orm = ImageTexture.create_from_image(orm)


## The patch is now `cells`. Those in `fresh` spread out from `from`,
## the furthest (`reach` away) arriving last; others already shown stay
## as they are, and any not shown yet appear at once.
func show_cells(cells: Array[SurfaceCell], fresh: Array[SurfaceCell], from: Vector3, reach: float) -> void:
	var now: float = _now()
	for cell in fresh:
		var d: float = Vector2(cell.centre().x - from.x, cell.centre().z - from.z).length()
		_arrive[cell.key] = now + spread_seconds * 0.6 * clampf(d / maxf(reach, SurfaceGrid.CELL), 0.0, 1.0)
		_dying.erase(cell.key)
	for cell in cells:
		if not _live.has(cell.key) and not _arrive.has(cell.key):
			_arrive[cell.key] = -INF
		_live[cell.key] = cell
	_changed()


## Thins `cells` away, then drops them.
func recede_cells(cells: Array[SurfaceCell]) -> void:
	var now: float = _now()
	for cell in cells:
		if _live.has(cell.key) and not _dying.has(cell.key):
			_dying[cell.key] = now
	_changed()


## The patch is now just `cells`, at once: what's left of a film another
## surface was cast over, once that one has spread over the rest.
func set_cells(cells: Array[SurfaceCell]) -> void:
	var keep: Dictionary[Vector2i, SurfaceCell] = {}
	for cell in cells:
		keep[cell.key] = cell
		if not _live.has(cell.key):
			_arrive[cell.key] = -INF
	for key in _live.keys():
		if not keep.has(key):
			_arrive.erase(key)
			_dying.erase(key)
	_live = keep
	_changed()


## Recedes every cell, then frees itself.
func dissipate() -> void:
	var now: float = _now()
	for key in _live:
		if not _dying.has(key):
			_dying[key] = now
	_changed()


## Called with the cells each time the decal's box moves to fit a new
## picture: for what stands on the cells (Fire's flames).
func _cells_shown(_cells: Array[SurfaceCell]) -> void:
	pass


func _changed() -> void:
	_shown = true
	_dirty = true
	_cells_dirty = true
	# The glow loop pictured the old cells.
	_glow_loop.clear()
	_glow_drawing = -1


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _process(_delta: float) -> void:
	if not _shown:
		return
	var now: float = _now()
	var animating: bool = false
	for key in _dying.keys():
		if now - _dying[key] >= recede_seconds:
			_dying.erase(key)
			_live.erase(key)
			_arrive.erase(key)
			_changed()
	if _live.is_empty():
		queue_free()
		return
	for key in _arrive:
		if now - _arrive[key] < spread_seconds * 0.4:
			animating = true
			break
	if not _dying.is_empty():
		animating = true
	if animating or _dirty:
		_dirty = false
		_draw_mask(now)
	elif glows and glow_frames > 0 and _glow_loop.is_empty() and _glow_drawing < 0 and not _copy_pending:
		_draw_glow(0)
	if glow_frames > 0 and _glow_loop.size() == glow_frames:
		var frame: int = int(now * glow_fps) % glow_frames
		texture_emission = _glow_loop[frame]


## Paints the cells into the mask and redraws the passes from it.
func _draw_mask(now: float) -> void:
	var low := Vector2i(1 << 30, 1 << 30)
	var high := -low
	var y_low: float = INF
	var y_high: float = -INF
	for key in _live:
		low = low.min(key)
		high = high.max(key)
		y_low = minf(y_low, _live[key].y)
		y_high = maxf(y_high, _live[key].y)
	var origin: Vector2i = low - Vector2i(PAD, PAD)
	var dims: Vector2i = high - low + Vector2i(1, 1) + Vector2i(PAD, PAD) * 2
	var image := Image.create(dims.x, dims.y, false, Image.FORMAT_RGBA8)
	var depth: Dictionary[Vector2i, float] = _depths()
	var ramp: float = maxf(spread_seconds * 0.4, 0.001)
	for key in _live:
		var arrival: float = clampf((now - _arrive.get(key, -INF)) / ramp, 0.0, 1.0)
		arrival = arrival * arrival * (3.0 - 2.0 * arrival)
		var recede: float = clampf((now - _dying[key]) / recede_seconds, 0.0, 1.0) if _dying.has(key) else 0.0
		image.set_pixelv(key - origin, Color(arrival * (1.0 - recede), clampf(depth[key] / 4.0, 0.0, 1.0), 0.0, recede))
	if _mask and _mask.get_size() == Vector2(dims):
		_mask.update(image)
	else:
		_mask = ImageTexture.create_from_image(image)
	var size_m := Vector2(dims) * SurfaceGrid.CELL
	var pixels := Vector2i((size_m * pixels_per_meter).round()).clamp(Vector2i(4, 4), Vector2i(max_resolution, max_resolution))
	for i in _viewports.size():
		_viewports[i].size = pixels
		_canvases[i].size = Vector2(pixels)
		_viewports[i].render_target_update_mode = SubViewport.UPDATE_ONCE
	for material in _materials:
		material.set_shader_parameter("cell_mask", _mask)
		material.set_shader_parameter("mask_cells", Vector2(dims))
		material.set_shader_parameter("origin_m", Vector2(origin) * SurfaceGrid.CELL)
		material.set_shader_parameter("size_m", size_m)
	var corner := Vector3(origin.x * SurfaceGrid.CELL, 0.0, origin.y * SurfaceGrid.CELL)
	_box_size = Vector3(size_m.x, y_high - y_low + REACH_Y * 2.0, size_m.y)
	_box_centre = corner + Vector3(size_m.x * 0.5, (y_low + y_high) * 0.5, size_m.y * 0.5)
	if _cells_dirty:
		_cells_dirty = false
		_box_cells.assign(_live.values())
		_box_pending = true
	_copy_pending = true


## Meters in from the patch's edge for each cell: the edge cells half a
## cell, each step further in one cell more.
func _depths() -> Dictionary[Vector2i, float]:
	var depth: Dictionary[Vector2i, float] = {}
	var frontier: Array[Vector2i] = []
	for key in _live:
		for step in SurfaceGrid.NEIGHBOURS:
			if not _live.has(key + step):
				depth[key] = SurfaceGrid.CELL * 0.5
				frontier.append(key)
				break
	var i: int = 0
	while i < frontier.size():
		var key: Vector2i = frontier[i]
		i += 1
		for step in SurfaceGrid.NEIGHBOURS:
			var next: Vector2i = key + step
			if _live.has(next) and not depth.has(next):
				depth[next] = depth[key] + SurfaceGrid.CELL
				frontier.append(next)
	return depth


func _exit_tree() -> void:
	RenderingServer.frame_post_draw.disconnect(_copy_drawn)


func _draw_glow(frame: int) -> void:
	_glow_drawing = frame
	_materials[2].set_shader_parameter("glow_phase", float(frame) / glow_frames)
	_viewports[2].render_target_update_mode = SubViewport.UPDATE_ONCE


## After the frame that redrew the viewports, their pictures into the
## decal's textures, and the decal's box onto the cells they picture.
func _copy_drawn() -> void:
	if _glow_drawing >= 0 and not _copy_pending:
		var image: Image = _viewports[2].get_texture().get_image()
		image.convert(Image.FORMAT_RGBA8)
		_glow_loop.append(ImageTexture.create_from_image(image))
		if _glow_loop.size() < glow_frames:
			_draw_glow(_glow_loop.size())
		else:
			_glow_drawing = -1
		return
	if not _copy_pending:
		return
	_copy_pending = false
	for i in _viewports.size():
		var image: Image = _viewports[i].get_texture().get_image()
		image.convert(Image.FORMAT_RGBA8)
		_textures[i] = ImageTexture.create_from_image(image)
	_show_textures()
	global_position = _box_centre
	size = _box_size
	if _box_pending:
		_box_pending = false
		_cells_shown(_box_cells)
	drawn.emit()


func _show_textures() -> void:
	texture_albedo = _textures[0]
	texture_normal = _textures[1]
	if glows:
		texture_emission = _textures[2]
