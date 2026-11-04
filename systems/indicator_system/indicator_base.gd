class_name IndicatorBase
extends Node3D
## Shared foundation for the preview indicators (movement path, jump arc,
## ranged/area line-of-sight, area ring, ...): the line-mesh setup every
## one of them needs, and the live/draw contract with ClickRouter.
##
## Indicators only DRAW. ClickRouter resolves the one Cursor and builds
## the one Aim each frame, and calls draw(aim) on every live indicator.
## No indicator raycasts, reads the mouse or Ctrl, or decides validity:
## colours come from the ability's own targeting.check(), and the path
## from Unit.preview_route(), the same rules the click and the move use.
## Before this, each indicator raycast for itself through a shared static
## cache and the Ctrl drag's held point was a static whichever live
## indicator wrote - "where is the player aiming" had three owners.

## Every MeshInstance3D this indicator built through _create_line_mesh(),
## so set_live(false) can put ALL of them away without each subclass
## hand-writing its own _hide_all() for the router to call. Subclasses
## still hide their own meshes mid-draw for their own reasons ("nothing
## under the cursor"); this is only for the router switching an indicator
## off wholesale.
var _owned_meshes: Array[MeshInstance3D] = []

## Whether the router currently draws this indicator. Written only by
## set_live (the router's _apply_intent).
var _live: bool = false


## Joins the group the ClickRouter walks.
##
## Subclasses that define their own _ready() MUST call super() — Godot
## calls only the most-derived _ready, so an override without it silently
## opts that indicator out of the router entirely.
func _ready() -> void:
	add_to_group(&"indicators")


## The intent id this indicator answers to — the id PlayerIntent.
## indicator_ids() names when this indicator should be live. One id per
## indicator, declared once here instead of re-derived every frame from
## the armed ability's targeting type.
##
## &"" means "not intent-driven": the sight cones and the nav overlay are
## development views with their own toggles and their own _process. The
## router skips anything returning &"" — see ClickRouter._apply_intent.
func serves() -> StringName:
	return &""


## Called by ClickRouter whenever the derived intent changes — the ONLY
## writer of whether an intent-driven indicator is drawn. Puts the
## visuals away on the way out so a line drawn for a since-abandoned
## intent can't be left hanging on screen.
func set_live(live: bool) -> void:
	_live = live
	if not live:
		hide_visuals()


func is_live() -> bool:
	return _live


## Draws this frame's aim. Called by ClickRouter once per frame while
## live, after the cursor is resolved and any height drag applied.
func draw(_aim: Aim) -> void:
	pass


func hide_visuals() -> void:
	for mesh in _owned_meshes:
		if is_instance_valid(mesh):
			mesh.visible = false


## Whether anything this indicator owns is currently drawn. Exists for
## the suite that asserts an indicator really goes dark rather than
## merely stopping — see tests/interaction/test_intent_has_one_owner.gd.
func is_showing_anything() -> bool:
	for mesh in _owned_meshes:
		if is_instance_valid(mesh) and mesh.visible:
			return true
	return false


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
	_owned_meshes.append(mesh_instance)

	return {"mesh_instance": mesh_instance, "immediate": immediate}
