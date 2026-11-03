class_name DecalSurface
extends Decal
## A surface drawn on the ground: Grease, Water, Ice, Blood... A Decal,
## so the film drapes over steps and slopes. A Decal can't run a shader,
## so `film` (a canvas_item shader built on film_passes.gdshaderinc) draws
## its albedo, normal map and, when it `glows`, emission in small
## SubViewports, redrawn only while the shape changes. A Decal doesn't
## show a ViewportTexture, so each redraw is copied into an ImageTexture.
## The outline is noise, different every cast. It spreads out when cast,
## and expiry calls dissipate(): thin film goes first, then it frees
## itself. Units wear Unit.RENDER_LAYER, which cull_mask leaves out, so
## the film paints the floor and not their feet.

## The look, edited in the inspector; each pass draws a copy of it.
@export var film: ShaderMaterial
## Also draw the film's emission pass, into texture_emission.
@export var glows: bool = false
@export var resolution: int = 512
@export var spread_seconds: float = 0.6
@export var recede_seconds: float = 1.5
## Low: the film is glossy, so it catches the scene's lights.
@export var roughness: float = 0.12

var _materials: Array[ShaderMaterial] = []
var _viewports: Array[SubViewport] = []
var _textures: Array[ImageTexture] = []
var _tween: Tween
var _copy_pending: bool = false


func _ready() -> void:
	var seed: float = randf() * 100.0
	for film_pass in ([0, 1, 2] if glows else [0, 1]):
		var viewport := SubViewport.new()
		viewport.size = Vector2i(resolution, resolution)
		viewport.disable_3d = true
		viewport.transparent_bg = true
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		var canvas := ColorRect.new()
		canvas.size = Vector2(viewport.size)
		var material := film.duplicate() as ShaderMaterial
		material.set_shader_parameter("film_pass", film_pass)
		material.set_shader_parameter("seed", seed)
		canvas.material = material
		viewport.add_child(canvas)
		add_child(viewport)
		_viewports.append(viewport)
		_materials.append(material)
	for _viewport in _viewports:
		var blank := Image.create(resolution, resolution, false, Image.FORMAT_RGBA8)
		_textures.append(ImageTexture.create_from_image(blank))
	_show_textures()
	RenderingServer.frame_post_draw.connect(_copy_drawn)
	var orm := Image.create(4, 4, false, Image.FORMAT_RGB8)
	orm.fill(Color(1.0, roughness, 0.0))
	texture_orm = ImageTexture.create_from_image(orm)
	_set_shape(0.0, 0.0)
	# Deferred: SurfaceManager scales this to the radius after add_child,
	# and the noise is sized in meters.
	_animate.call_deferred(func(t: float) -> void: _set_shape(t, 0.0), spread_seconds, false)


func dissipate() -> void:
	_animate(func(t: float) -> void: _set_shape(1.0, t), recede_seconds, true)


func _animate(method: Callable, seconds: float, free_after: bool) -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_method(method, 0.0, 1.0, seconds).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if free_after:
		_tween.tween_callback(queue_free)


func _set_shape(spread: float, recede: float) -> void:
	for material in _materials:
		material.set_shader_parameter("spread", spread)
		material.set_shader_parameter("recede", recede)
		material.set_shader_parameter("radius_m", size.x * 0.5 * scale.x)
	for viewport in _viewports:
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_copy_pending = true


func _exit_tree() -> void:
	RenderingServer.frame_post_draw.disconnect(_copy_drawn)


## After the frame that redrew the viewports, their pictures into the
## decal's textures.
func _copy_drawn() -> void:
	if not _copy_pending:
		return
	_copy_pending = false
	for i in _viewports.size():
		var image: Image = _viewports[i].get_texture().get_image()
		image.convert(Image.FORMAT_RGBA8)
		_textures[i] = ImageTexture.create_from_image(image)
	_show_textures()


func _show_textures() -> void:
	texture_albedo = _textures[0]
	texture_normal = _textures[1]
	if glows:
		texture_emission = _textures[2]
