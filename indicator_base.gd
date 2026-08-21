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

## Shared across EVERY IndicatorBase instance (static, not per-node) —
## keyed by collision mask, holding the last raycast result for that
## mask plus the engine frame it was taken on. Up to several different
## indicator NODES (movement preview, aim-facing, a targeting line, ...)
## can all be active at once and all want "what's under the mouse right
## now" within the same single frame — a per-instance cache can't
## de-duplicate THAT (each node would still do its own first-call miss),
## only a cache shared across instances can. Frame-stamped rather than
## cleared explicitly: a stale entry simply never matches the current
## frame number, so there's no separate invalidation step needed, and
## at most a couple of distinct mask values ever exist project-wide, so
## this can't grow unbounded either.
static var _raycast_cache: Dictionary = {}


## The one raycast every helper below needs, differing only in mask and
## what's done with the result — see _raycast_cache's own doc comment
## for why this is cached per-mask-per-frame rather than run fresh on
## every call. Returns the raw intersect_ray() Dictionary (empty if
## nothing hit, or if there's no active camera at all).
func _raycast_from_mouse(collision_mask: int) -> Dictionary:
	var current_frame: int = Engine.get_process_frames()
	if _raycast_cache.has(collision_mask) and _raycast_cache[collision_mask].frame == current_frame:
		return _raycast_cache[collision_mask].result

	var result: Dictionary = {}
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera:
		var mouse_pos: Vector2 = get_viewport().get_mouse_position()
		var from: Vector3 = camera.project_ray_origin(mouse_pos)
		var dir: Vector3 = camera.project_ray_normal(mouse_pos)
		var to: Vector3 = from + dir * 1000.0

		var space_state := get_world_3d().direct_space_state
		var query := PhysicsRayQueryParameters3D.create(from, to)
		query.collision_mask = collision_mask
		result = space_state.intersect_ray(query)

	_raycast_cache[collision_mask] = {"frame": current_frame, "result": result}
	return result


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
## there.
func _get_mouse_ground_point():
	var result := _raycast_from_mouse(ground_collision_mask)
	if result.is_empty():
		return null
	return result.position


## The Unit currently under the mouse cursor, unfiltered (alive/hostile
## checks are the caller's job, since which filters make sense differ
## per indicator). Returns null if nothing's there or whatever's there
## isn't a Unit.
func _get_hovered_unit() -> Unit:
	var result := _raycast_from_mouse(unit_collision_mask)
	if result.is_empty():
		return null
	return result.get("collider") as Unit


## The interactable currently under the mouse cursor, or null — same
## raycast as _get_hovered_unit() (same collision mask, same ray), but
## duck-typed via has_method() instead of cast to Unit, so it matches
## ANY interactable (Unit, InteractableProp, anything future) rather than
## only Unit specifically. _get_hovered_unit() itself is left alone —
## its existing callers genuinely want a real Unit, not anything
## interactable.
func _get_hovered_interactable() -> Node:
	var result := _raycast_from_mouse(unit_collision_mask)
	if result.is_empty():
		return null
	var collider = result.get("collider")
	if collider is Node and collider.has_method("get_interactions"):
		return collider
	return null


## The hovered unit (see _get_hovered_unit), filtered to "alive and
## hostile to acting_unit" — null if nothing's hovered, it's dead, or
## it's not actually hostile. Every indicator that only cares about
## valid attack targets (not just whatever's under the cursor) wants
## exactly this.
func _get_hovered_hostile(acting_unit: Unit) -> Unit:
	var hovered := _get_hovered_unit()
	if not hovered or not hovered.is_alive():
		return null
	if not acting_unit.is_hostile_to(hovered):
		return null
	return hovered


## The unit currently being commanded, in or out of combat — see
## PlayerInteractionState.get_active_unit(). Most indicators want
## exactly this with no further filtering; override where a subclass
## genuinely needs something different — see movement_indicator.gd/
## unit_aim_facing.gd, which both add their own extra armed-ability
## condition on top, in OPPOSITE directions (one hides while something's
## armed, the other only shows while something is), so neither is a
## duplicate of this default despite looking similar at a glance.
func _get_active_unit() -> Unit:
	return PlayerInteractionState.get_active_unit()


## Reads the height/altitude implied by the current mouse position: casts
## the camera ray through the mouse and intersects it with a vertical
## plane anchored at anchor_xz. The plane's normal is the camera's own
## back vector flattened to purely horizontal (Y zeroed before
## normalizing) — flattening it is what keeps this a true vertical wall
## regardless of the camera's own pitch, so only how high or low the ray
## crosses that wall matters. Without flattening, a pitched-down camera
## would tilt the "wall" too, coupling horizontal mouse movement into the
## height result in a way that would feel wrong to drag. Returns null if
## there's no active camera or the ray can't hit the plane at all
## (near-parallel to it). Shared by anything that lets the player
## Ctrl-drag a height/altitude value while aiming — movement_indicator.gd's
## flight-altitude control and aerial_area_indicator.gd's blast-height
## control both used to carry an identical private copy of exactly this.
func _sample_height_from_mouse(anchor_xz: Vector2):
	var camera: Camera3D = get_viewport().get_camera_3d()
	if not camera:
		return null

	var back: Vector3 = camera.global_transform.basis.z
	var normal := Vector3(back.x, 0.0, back.z)
	if normal.length() < 0.001:
		return null
	normal = normal.normalized()

	var anchor_point := Vector3(anchor_xz.x, 0.0, anchor_xz.y)
	var plane := Plane(normal, anchor_point)

	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = camera.project_ray_origin(mouse_pos)
	var dir: Vector3 = camera.project_ray_normal(mouse_pos)

	var hit = plane.intersects_ray(from, dir)
	if hit == null:
		return null
	return hit.y
