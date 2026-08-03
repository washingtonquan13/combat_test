class_name UnitSelection
extends RefCounted
## Owns hover/selection/box-hover state and the visual highlight/outline
## update logic for ONE unit. Owned by that Unit (see Unit._selection),
## same pattern as StatusManager/UnitActionState/UnitFacing.
##
## highlight_mesh/outline_mesh/hover_color/selected_color stay as plain
## @export vars directly on Unit rather than moving in here — same
## editor-safety reasoning as UnitFacing's rotation_speed/
## facing_offset_degrees: the editor needs to read/write @export values
## before this component ever exists. This component reads them back
## through its owner reference when it needs them.
##
## Declares its OWN hover_started/hover_ended/selected/deselected
## signals rather than emitting directly on Unit's — Unit relays each
## one in _ready(), same became_idle relay pattern UnitActionState uses,
## so unit.hover_started.connect(...) etc keep working completely
## unchanged for any external code (nothing currently connects to these
## four, but they're part of Unit's public API and should stay stable
## regardless of what's actually listening today).

signal hover_started()
signal hover_ended()
signal selected()
signal deselected()

var is_hovered: bool = false
var is_selected: bool = false
var box_hovered: bool = false

var _owner: Unit
var _highlight_material: StandardMaterial3D


func _init(owner: Unit) -> void:
	_owner = owner


func setup() -> void:
	if _owner.highlight_mesh:
		# Give this unit its own material instance so its ring can
		# change color independently of any siblings sharing the same
		# base mesh.
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_highlight_material = mat
		_owner.highlight_mesh.material_override = mat
		_owner.highlight_mesh.visible = false

	if _owner.outline_mesh:
		_owner.outline_mesh.visible = false


func on_mouse_entered() -> void:
	is_hovered = true
	hover_started.emit()
	update_highlight()


func on_mouse_exited() -> void:
	is_hovered = false
	hover_ended.emit()
	update_highlight()


## Selection state is owned by SelectionManager — call
## SelectionManager.select()/deselect() rather than this directly, so the
## manager's selected_units list and this unit's state never drift apart.
func set_selected(value: bool) -> void:
	if is_selected == value:
		return
	is_selected = value
	if value:
		selected.emit()
	else:
		deselected.emit()
	update_highlight()


## Called by a drag-select box while it's overlapping this unit, purely as
## a visual preview — does not touch is_selected or SelectionManager.
func set_box_hover(value: bool) -> void:
	if box_hovered == value:
		return
	box_hovered = value
	update_highlight()


func update_highlight() -> void:
	var state_color: Variant = null
	var show: bool = false

	if is_selected:
		show = true
		state_color = _owner.selected_color
	elif is_hovered or box_hovered:
		show = true
		state_color = _owner.hover_color

	if _owner.highlight_mesh:
		_owner.highlight_mesh.visible = show
		if show:
			_highlight_material.albedo_color = state_color

	if _owner.outline_mesh:
		_owner.outline_mesh.visible = show
		if show:
			var outline_material := _owner.outline_mesh.material_override as ShaderMaterial
			if outline_material:
				outline_material.set_shader_parameter("outline_color", state_color)
