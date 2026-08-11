class_name IndicatorBase
extends Node3D
## Shared foundation for the combat preview indicators (movement path,
## jump arc, ranged/area line-of-sight, area ring). Before this, all four
## independently hand-built near-identical MeshInstance3D/ImmediateMesh/
## material setups and near-identical raycast helpers — this factors
## that boilerplate out once so subclasses only need to decide WHAT to
## draw and WHEN, not HOW to build a line mesh or cast a ray.
##
## Subclasses still own their OWN visibility/business logic (which
## ability type they care about, what colors mean what) — this isn't
## trying to unify that, only the mechanical parts that were genuinely
## identical across all four.

@export var ground_collision_mask: int = 1
@export var unit_collision_mask: int = 1


## Creates a new MeshInstance3D + ImmediateMesh configured for
## vertex-colored, unshaded, alpha-blended line/ring drawing — the exact
## material setup every indicator needs (SHADING_MODE_UNSHADED,
## vertex_color_use_as_albedo, TRANSPARENCY_ALPHA, CULL_DISABLED),
## previously hand-assembled identically in each one's own _build_line()/
## _build_ring(). Starts hidden. Returns both pieces: add the mesh
## instance as a child (already done here) and toggle its .visible;
## call clear_surfaces()/surface_begin()/surface_add_vertex()/
## surface_end() on the ImmediateMesh each frame to redraw.
func _create_line_mesh() -> Dictionary:
	var mesh_instance := MeshInstance3D.new()
	add_child(mesh_instance)

	var immediate := ImmediateMesh.new()
	mesh_instance.mesh = immediate

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh_instance.material_override = mat
	mesh_instance.visible = false

	return {"mesh_instance": mesh_instance, "immediate": immediate}


## Ground point under the current mouse position, or null if nothing's
## there — the raycast pattern movement_indicator.gd, jump_indicator.gd,
## area_indicator.gd, and line_of_sight_indicator.gd's ground fallback
## each independently rebuilt.
func _get_mouse_ground_point():
	var camera: Camera3D = get_viewport().get_camera_3d()
	if not camera:
		return null

	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = camera.project_ray_origin(mouse_pos)
	var dir: Vector3 = camera.project_ray_normal(mouse_pos)
	var to: Vector3 = from + dir * 1000.0

	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = ground_collision_mask
	var result := space_state.intersect_ray(query)

	if result.is_empty():
		return null
	return result.position


## The Unit currently under the mouse cursor, unfiltered (alive/hostile
## checks are the caller's job, since which filters make sense differ
## per indicator) — the raycast pattern line_of_sight_indicator.gd
## rebuilt for its own hover check. Returns null if nothing's there or
## whatever's there isn't a Unit.
func _get_hovered_unit() -> Unit:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if not camera:
		return null

	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = camera.project_ray_origin(mouse_pos)
	var dir: Vector3 = camera.project_ray_normal(mouse_pos)
	var to: Vector3 = from + dir * 1000.0

	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = unit_collision_mask
	var result := space_state.intersect_ray(query)

	if result.is_empty():
		return null
	return result.get("collider") as Unit


## The interactable currently under the mouse cursor, or null — same
## raycast as _get_hovered_unit() (same collision mask, same ray), but
## duck-typed via has_method() instead of cast to Unit, so it matches
## ANY interactable (Unit, InteractableProp, anything future) rather than
## only Unit specifically. _get_hovered_unit() itself is left alone —
## its existing callers (line_of_sight_indicator.gd, etc.) genuinely want
## a real Unit, not anything interactable.
func _get_hovered_interactable() -> Node:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if not camera:
		return null

	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = camera.project_ray_origin(mouse_pos)
	var dir: Vector3 = camera.project_ray_normal(mouse_pos)
	var to: Vector3 = from + dir * 1000.0

	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = unit_collision_mask
	var result := space_state.intersect_ray(query)

	if result.is_empty():
		return null
	var collider = result.get("collider")
	if collider is Node and collider.has_method("get_interactions"):
		return collider
	return null
