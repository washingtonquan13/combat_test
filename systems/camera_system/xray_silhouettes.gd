class_name XRaySilhouettes
extends Node
## Shows units through walls: each eligible unit's body meshes wear
## xray_silhouette.gdshader as their material_overlay, which tints the body
## in its relation colour wherever opaque geometry hides it and draws
## nothing where it is in plain view (the shader decides per pixel, so a
## unit half behind a crate shows only its hidden half).
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
## purpose.
##
## Non-destructive: an overlay is only written onto a mesh whose overlay is
## empty (or already ours), and only cleared if it is still ours, so the
## cinematic silhouette beat (which also uses material_overlay) wins
## whenever it is active and gets its mesh back untouched. Membership is
## re-evaluated every refresh_interval seconds rather than tracked through
## signals, which also picks up swapped bodies and newly drawn weapons
## (both are meshes under the CharacterModel) without hooks.

const SHADER: Shader = preload("res://systems/camera_system/xray_silhouette.gdshader")

var enabled: bool = true
var show_enemies: bool = true
var fill_alpha: float = 0.22
var rim_alpha: float = 0.55
var occlusion_bias: float = 0.3
var refresh_interval: float = 0.25

var _camera: Camera3D
var _party_material: ShaderMaterial
var _enemy_material: ShaderMaterial
## instance_id -> MeshInstance3D currently wearing one of our overlays.
## Keyed by id, not by node, so a freed mesh can still be looked up and
## dropped (is_instance_valid on the stored value).
var _painted: Dictionary = {}
var _since_refresh: float = INF


func setup(camera: Camera3D) -> void:
	_camera = camera
	_party_material = _make_material(IndicatorPalette.PARTY)
	_enemy_material = _make_material(IndicatorPalette.ENEMY)


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
	clear()


## Takes every overlay this node put on and forgets them.
func clear() -> void:
	for id in _painted.keys():
		_unpaint(id)
	_painted.clear()


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
