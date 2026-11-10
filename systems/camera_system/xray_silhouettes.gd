class_name XRaySilhouettes
extends Node
## Shows units through walls: each eligible unit's body meshes wear
## xray_silhouette.gdshader as their material_overlay, which tints the body
## in its relation colour wherever opaque geometry hides it and draws
## nothing where it is in plain view (the shader decides per pixel, so a
## unit half behind a crate shows only its hidden half).
##
## Only LEVEL geometry hides a unit. The shader tests against a depth
## render of the level alone, made here: a SubViewport sharing the
## camera's World3D, whose camera copies the player's camera just before
## every frame is drawn (RenderingServer.frame_pre_draw) and leaves
## Unit.RENDER_LAYER, which every body and held item wears, out of its
## cull_mask. A full-screen quad on CAPTURE_LAYER turns that viewport's
## depth into linear metres (level_depth_capture.gdshader). The viewport is
## drawn unshaded, at depth_scale of the screen, and only while some unit
## wears an overlay; the rest of the time it costs nothing.
##
## Owned by CRPGCamera, which creates one as its child and pushes its own
## X-Ray export group into it (see CRPGCamera._setup_xray). It lives with
## the camera rather than on Unit because it is a question about what THIS
## camera can see, and because it keeps unit.gd and character_model.gd
## untouched: a body never has to know it can be x-rayed.
##
## Who gets one:
##   - every player-controlled unit (party members, their demons, summons),
##     PARTY blue;
##   - a hostile unit in a running fight that a party unit is also in,
##     ENEMY vermillion. A sleeping goblin behind a wall before the fight
##     starts stays a surprise; once the party is fighting it, hiding it
##     behind a pillar only costs the player information they already have.
## Hidden bodies (is_visible_in_tree false: a unit made invisible by some
## other system) are skipped, so this never reveals what was hidden on
## purpose. So is a unit in UNDER_GROUND (Puddle Step sinking it through
## the floor): the floor hides it on purpose, not by accident of the view.
##
## Non-destructive: an overlay is only written onto a mesh whose overlay is
## empty (or already ours), and only cleared if it is still ours, so the
## cinematic silhouette beat (which also uses material_overlay) wins
## whenever it is active and gets its mesh back untouched. Membership is
## re-evaluated every refresh_interval seconds rather than tracked through
## signals, which also picks up swapped bodies and newly drawn weapons
## (both are meshes under the CharacterModel) without hooks.

const SHADER: Shader = preload("res://systems/camera_system/xray_silhouette.gdshader")
const CAPTURE_SHADER: Shader = preload("res://systems/camera_system/level_depth_capture.gdshader")
## Render layer only the depth capture quad wears. The player's camera
## leaves it out (setup), so the quad is never seen on screen.
const CAPTURE_LAYER: int = 20
## Render layer for level geometry that never hides a unit: grass, ferns,
## ground plants, vines. The depth render leaves it out, so a goblin
## standing in grass gets no silhouette, and that foliage isn't drawn twice.
const SEE_THROUGH_LAYER: int = 19
## Units in this group are under the floor on purpose and get no
## silhouette. Whoever adds one calls refresh_all, so the silhouette goes
## the same frame rather than at the next refresh.
const UNDER_GROUND: StringName = &"under_ground"
const GROUP: StringName = &"xray_silhouettes"

var enabled: bool = true
var show_enemies: bool = true
var fill_alpha: float = 0.22
var rim_alpha: float = 0.55
var occlusion_bias: float = 0.1
## Level depth resolution as a fraction of the camera's viewport.
var depth_scale: float = 0.5
var refresh_interval: float = 0.25

var _camera: Camera3D
var _party_material: ShaderMaterial
var _enemy_material: ShaderMaterial
## instance_id -> MeshInstance3D currently wearing one of our overlays.
## Keyed by id, not by node, so a freed mesh can still be looked up and
## dropped (is_instance_valid on the stored value).
var _painted: Dictionary = {}
var _since_refresh: float = INF
var _depth_viewport: SubViewport
var _depth_camera: Camera3D
var _capture_quad: MeshInstance3D


func setup(camera: Camera3D) -> void:
	_camera = camera
	_camera.cull_mask &= ~_layer_bit(CAPTURE_LAYER)
	_build_depth_viewport()
	_party_material = _make_material(IndicatorPalette.PARTY)
	_enemy_material = _make_material(IndicatorPalette.ENEMY)


static func _layer_bit(layer: int) -> int:
	return 1 << (layer - 1)


## The level-only depth render the silhouettes test against. own_world_3d
## stays false, so it draws whatever World3D the camera's own viewport
## draws (each world lives in its own SubViewport; see WorldManager).
func _build_depth_viewport() -> void:
	_depth_viewport = SubViewport.new()
	_depth_viewport.name = "LevelDepth"
	# Float colour, so the metres the quad writes arrive unclamped.
	_depth_viewport.use_hdr_2d = true
	_depth_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_depth_viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	_depth_viewport.use_taa = false
	_depth_viewport.positional_shadow_atlas_size = 0
	# Lighting is never looked at here; only depth and the quad matter.
	_depth_viewport.debug_draw = Viewport.DEBUG_DRAW_UNSHADED
	_depth_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_depth_viewport.size = Vector2i(2, 2)
	add_child(_depth_viewport)

	_depth_camera = Camera3D.new()
	_depth_camera.name = "DepthCamera"
	_depth_camera.cull_mask = 0xFFFFF & ~_layer_bit(Unit.RENDER_LAYER) & ~_layer_bit(SEE_THROUGH_LAYER)
	# Its own plain Environment and attributes, so the world's tonemap,
	# exposure, glow and fog never touch the numbers the quad writes.
	_depth_camera.environment = Environment.new()
	_depth_camera.attributes = CameraAttributesPractical.new()
	_depth_viewport.add_child(_depth_camera)
	_depth_camera.current = true

	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	var material := ShaderMaterial.new()
	material.shader = CAPTURE_SHADER
	_capture_quad = MeshInstance3D.new()
	_capture_quad.name = "CaptureQuad"
	_capture_quad.mesh = quad
	_capture_quad.material_override = material
	_capture_quad.layers = _layer_bit(CAPTURE_LAYER)
	_capture_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_capture_quad.ignore_occlusion_culling = true
	# The vertex shader pins it to the screen wherever it is; this keeps
	# frustum culling from ever dropping it.
	_capture_quad.custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))
	_capture_quad.visible = false
	_depth_camera.add_child(_capture_quad)


func _enter_tree() -> void:
	add_to_group(GROUP)
	if not RenderingServer.frame_pre_draw.is_connected(_sync_depth_camera):
		RenderingServer.frame_pre_draw.connect(_sync_depth_camera)


## Runs after every node has moved this frame and before anything is
## drawn, so the depth render and the screen it is read on share one view.
func _sync_depth_camera() -> void:
	var active: bool = not _painted.is_empty() and is_instance_valid(_camera) 		and _camera.is_inside_tree() and _camera.current
	_depth_viewport.render_target_update_mode = 		SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED
	# A camera in another viewport of this world sees CAPTURE_LAYER too;
	# shown only while the capture runs, it is only there while ours is.
	_capture_quad.visible = active
	if not active:
		return
	var screen: Vector2 = _camera.get_viewport().get_visible_rect().size
	var wanted := Vector2i(maxi(1, roundi(screen.x * depth_scale)), maxi(1, roundi(screen.y * depth_scale)))
	if _depth_viewport.size != wanted:
		_depth_viewport.size = wanted
	_depth_camera.global_transform = _camera.global_transform
	_depth_camera.projection = _camera.projection
	_depth_camera.keep_aspect = _camera.keep_aspect
	_depth_camera.fov = _camera.fov
	_depth_camera.size = _camera.size
	_depth_camera.frustum_offset = _camera.frustum_offset
	_depth_camera.h_offset = _camera.h_offset
	_depth_camera.v_offset = _camera.v_offset
	_depth_camera.near = _camera.near
	_depth_camera.far = _camera.far


## Re-pushes the knobs into both materials. Call after changing any of
## the alpha/bias fields at runtime.
func apply_settings() -> void:
	for material in [_party_material, _enemy_material]:
		if material == null:
			continue
		material.set_shader_parameter("fill_alpha", fill_alpha)
		material.set_shader_parameter("rim_alpha", rim_alpha)
		material.set_shader_parameter("occlusion_bias", occlusion_bias)
	_since_refresh = INF


func _make_material(color: Color) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("silhouette_color", color)
	material.set_shader_parameter("fill_alpha", fill_alpha)
	material.set_shader_parameter("rim_alpha", rim_alpha)
	material.set_shader_parameter("occlusion_bias", occlusion_bias)
	material.set_shader_parameter("level_depth", _depth_viewport.get_texture())
	# Over everything else transparent (fire, fog), so the outline is not
	# buried in a cloud the unit is standing in.
	material.render_priority = 10
	return material


func _process(delta: float) -> void:
	_since_refresh += delta
	if _since_refresh < refresh_interval:
		return
	_since_refresh = 0.0
	_refresh()


func _exit_tree() -> void:
	if RenderingServer.frame_pre_draw.is_connected(_sync_depth_camera):
		RenderingServer.frame_pre_draw.disconnect(_sync_depth_camera)
	clear()


## Takes every overlay this node put on and forgets them.
func clear() -> void:
	for id in _painted.keys():
		_unpaint(id)
	_painted.clear()


## Re-evaluates every silhouette now, in every world.
static func refresh_all(tree: SceneTree) -> void:
	tree.call_group(GROUP, "_refresh")


func _refresh() -> void:
	var wanted: Dictionary = {}
	# Only while this camera is the one being looked through: a cinematic
	# camera has its own ideas about what should glow.
	if enabled and is_instance_valid(_camera) and _camera.is_inside_tree() and _camera.current:
		_collect(wanted)

	for id in _painted.keys():
		if not wanted.has(id):
			_unpaint(id)
			_painted.erase(id)

	for id in wanted:
		var mesh: MeshInstance3D = wanted[id][0]
		var material: ShaderMaterial = wanted[id][1]
		if mesh.material_overlay == material:
			_painted[id] = mesh
			continue
		# Someone else's overlay: leave it, and do not claim the mesh.
		if mesh.material_overlay != null and not _is_ours(mesh.material_overlay):
			_painted.erase(id)
			continue
		mesh.material_overlay = material
		_painted[id] = mesh


func _collect(wanted: Dictionary) -> void:
	var world: World3D = _camera.get_world_3d()
	var units: Array[Unit] = UnitQuery.all_units(get_tree())
	var party_encounters: Array = []
	for unit in units:
		if unit.is_player_controlled() and unit.encounter != null and unit.in_combat():
			if unit.encounter not in party_encounters:
				party_encounters.append(unit.encounter)

	for unit in units:
		if unit.get_world_3d() != world:
			continue
		var material: ShaderMaterial = _material_for(unit, party_encounters)
		if material == null:
			continue
		if unit.is_in_group(UNDER_GROUND):
			continue
		var body := unit.get_node_or_null("CharacterModel") as Node3D
		if body == null or not body.is_visible_in_tree():
			continue
		for node in body.find_children("*", "MeshInstance3D", true, false):
			var mesh := node as MeshInstance3D
			# The outline hull and the foot ring are indicators, not body.
			if mesh == unit.outline_mesh or mesh == unit.highlight_mesh:
				continue
			wanted[mesh.get_instance_id()] = [mesh, material]


func _material_for(unit: Unit, party_encounters: Array) -> ShaderMaterial:
	if unit.is_player_controlled():
		return _party_material
	if not show_enemies or not unit.in_combat():
		return null
	if unit.encounter not in party_encounters:
		return null
	if not FactionRelations.is_hostile(Unit.PLAYER_FACTION, unit.faction):
		return null
	return _enemy_material


func _unpaint(id: int) -> void:
	# Untyped on purpose: the mesh may already be freed, and assigning a
	# freed instance to a typed variable is itself an error.
	var mesh = _painted.get(id)
	if is_instance_valid(mesh) and _is_ours(mesh.material_overlay):
		mesh.material_overlay = null


func _is_ours(material: Material) -> bool:
	return material != null and (material == _party_material or material == _enemy_material)
