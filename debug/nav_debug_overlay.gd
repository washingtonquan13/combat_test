extends IndicatorBase
## Toggleable 3D debug visualization of NavigationGrid validity — a voxel
## grid of small colored cubes sampled through a real volume around the
## mouse's ground hover point (horizontally AND vertically, not one flat
## slice), using the exact same NavigationGrid.nearest_valid_point()
## query real movement and Ladder._climb_path_is_clear already use — so
## this can never show an answer that disagrees with what the game
## itself thinks is walkable/flyable.
##
## Toggle with the toggle_nav_debug InputMap action (F3 by default — see
## project.godot > Input Map). Off by default; this is a development
## tool, not player-facing UI.
##
## Every sample point is checked BOTH ways (grounded AND flying) and
## colored by the combination:
##   green  = grounded-walkable only
##   blue   = flying-valid only
##   yellow = both
##   red    = neither (only drawn if show_blocked is on — see below)
## Expected, not a bug: everything sampled below
## NavigationGrid.get_flight_min_altitude() always comes back
## grounded-only at best, never blue/yellow — the same "can't hover at
## ground level" game rule Ladder._climb_path_is_clear's own header
## documents. You'll see it as a visible horizontal boundary in the view.
##
## Rendered via MultiMeshInstance3D (one shared unit BoxMesh, per-instance
## position + color) rather than hand-building triangles like the other
## indicators — this is routinely thousands of boxes per rebuild, and
## GPU instancing is what actually scales for that, not an ImmediateMesh
## rebuilt vertex-by-vertex every time the mouse moves.

@export var horizontal_radius: float = 4.0
@export var vertical_radius: float = 3.0
@export var sample_spacing: float = 0.5
## Roughly a default Unit's radius + avoidance_margin (see unit.gd) — how
## much clearance each query checks for, not just a single dimensionless
## point.
@export var clearance: float = 0.4
@export var grounded_color: Color = Color(0, 1, 0, 0.3)
@export var flying_color: Color = Color(0.2, 0.6, 1.0, 0.3)
@export var both_color: Color = Color(1, 1, 0, 0.35)
@export var blocked_color: Color = Color(1, 0, 0, 0.2)
## Off by default — showing every solid cell too roughly re-traces level
## geometry you can already see, and it's by far the largest category
## near any mostly-solid area. Flip on for the literal full picture.
@export var show_blocked: bool = false
## Edge length of each drawn cube — kept smaller than sample_spacing so
## neighboring cubes don't touch; the gap is what makes this read as a
## grid instead of a solid slab.
@export var cell_visual_size: float = 0.35

var _enabled: bool = false
var _multimesh_instance: MultiMeshInstance3D
var _multimesh: MultiMesh
var _last_center: Vector3 = Vector3.ZERO
var _has_last_center: bool = false


func _ready() -> void:
	var box := BoxMesh.new()
	box.size = Vector3.ONE * cell_visual_size

	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.use_colors = true
	_multimesh.mesh = box

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Deliberately NOT cull-disabled, unlike IndicatorBase's own flat-quad
	# material (_create_line_mesh) — these are real enclosed boxes with a
	# well-defined outside, not single-sided ribbons, so normal backface
	# culling is correct here.

	_multimesh_instance = MultiMeshInstance3D.new()
	_multimesh_instance.multimesh = _multimesh
	_multimesh_instance.material_override = mat
	_multimesh_instance.visible = false
	add_child(_multimesh_instance)


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("toggle_nav_debug"):
		return
	_enabled = not _enabled
	_multimesh_instance.visible = _enabled
	if _enabled:
		_has_last_center = false
	else:
		_multimesh.instance_count = 0


func _process(_delta: float) -> void:
	if not _enabled:
		return

	var ground_point = _get_mouse_ground_point()
	if ground_point == null:
		return

	if _has_last_center and ground_point.distance_to(_last_center) < sample_spacing:
		return
	_last_center = ground_point
	_has_last_center = true

	_rebuild(ground_point)


## Exact, no-snap queries (max_radius_cells=0) — see
## Ladder._climb_path_is_clear for why 0 can occasionally misclassify a
## point sitting exactly ON a surface boundary. Fine here: a stray
## wrong-colored cube right at an edge is a debug-tool quirk, not a
## correctness bug the way it would be for an actual climb.
func _rebuild(center: Vector3) -> void:
	var tree: SceneTree = get_tree()
	var transforms: Array[Transform3D] = []
	var colors: Array[Color] = []

	var h_steps: int = int(horizontal_radius / sample_spacing)
	var v_steps: int = int(vertical_radius / sample_spacing)
	for xi in range(-h_steps, h_steps + 1):
		for zi in range(-h_steps, h_steps + 1):
			for yi in range(-v_steps, v_steps + 1):
				var sample: Vector3 = center + Vector3(xi * sample_spacing, yi * sample_spacing, zi * sample_spacing)
				var grounded: bool = NavigationGrid.nearest_valid_point(tree, sample, clearance, false, null, 0).found
				var flying: bool = NavigationGrid.nearest_valid_point(tree, sample, clearance, true, null, 0).found

				var color: Color
				if grounded and flying:
					color = both_color
				elif grounded:
					color = grounded_color
				elif flying:
					color = flying_color
				elif show_blocked:
					color = blocked_color
				else:
					continue

				transforms.append(Transform3D(Basis(), sample))
				colors.append(color)

	_multimesh.instance_count = transforms.size()
	for i in range(transforms.size()):
		_multimesh.set_instance_transform(i, transforms[i])
		_multimesh.set_instance_color(i, colors[i])
