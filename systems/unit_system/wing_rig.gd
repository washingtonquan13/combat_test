class_name WingRig
extends Node3D
## A pair of wings worn on a body's back: a separate rigged asset with its
## own AnimationPlayer, folded on the ground and spread aloft.
##
## Put it as a child of a CharacterModel (see fairy_model.tscn). On ready it
## moves itself onto a BoneAttachment3D on the first of mount_bones the
## skeleton has, placed so that at the rest pose its origin sits at
## mount_point, the way CharacterModel builds a sheath. From then on it
## follows CharacterModel.aloft: going up plays unfold_clip into
## flutter_clip, coming down fold_clip into folded_clip.
##
## The body's own clips never mention the wings, and the wings never read
## the body's clip: a fairy casting in the air is still aloft, so the
## state, not the animation playing, decides.

@export var mount_bones: Array[StringName] = [&"UpperChest", &"Chest", &"Spine"]
## Where the wings' origin sits on the back, in skeleton space at rest.
@export var mount_point: Vector3 = Vector3(0.0, 1.36, -0.175)
## Replaces the imported mesh's material on every surface.
@export var membrane: Material

@export_group("Clips")
@export var folded_clip: StringName = &"Folded"
@export var unfold_clip: StringName = &"Unfold"
@export var flutter_clip: StringName = &"Flutter"
@export var fold_clip: StringName = &"Fold"
## Speeds the flutter up or down; the clip is authored at three beats a
## second.
@export var flutter_speed: float = 1.0
@export var blend: float = 0.08

var _model: CharacterModel = null
var _player: AnimationPlayer = null


func _ready() -> void:
	_player = _find_player(self)
	for mesh: MeshInstance3D in find_children("*", "MeshInstance3D", true, false):
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if membrane:
			mesh.material_override = membrane
	_model = _find_model()
	if _model:
		_model.aloft_changed.connect(_on_aloft_changed)
	_show(_model != null and _model.aloft, false)
	mount.call_deferred()


## Moves onto the back bone. Returns whether it is mounted; false is a body
## with none of mount_bones, which leaves the wings where they were put.
func mount() -> bool:
	var parent := get_parent()
	if parent is BoneAttachment3D and parent.name == "WingMount":
		return true
	if _model == null:
		return false
	var skeleton: Skeleton3D = _find_skeleton(_model)
	if skeleton == null:
		return false
	var bone := -1
	for bone_name: StringName in mount_bones:
		bone = skeleton.find_bone(bone_name)
		if bone != -1:
			break
	if bone == -1:
		return false
	var attachment := BoneAttachment3D.new()
	attachment.name = "WingMount"
	skeleton.add_child(attachment)
	attachment.bone_name = skeleton.get_bone_name(bone)
	reparent(attachment, false)
	transform = skeleton.get_bone_global_rest(bone).affine_inverse() * Transform3D(Basis.IDENTITY, mount_point)
	return true


## Holds `clip` at `time`, for the anim lab's review sheets.
func pose_at(clip: StringName, time: float) -> void:
	if _player == null or not _player.has_animation(clip):
		return
	_player.play(clip, 0.0)
	_player.seek(minf(time, _player.get_animation(clip).length), true)
	_player.pause()


func _on_aloft_changed(aloft: bool) -> void:
	_show(aloft, true)


func _show(aloft: bool, animate: bool) -> void:
	if _player == null:
		return
	_player.clear_queue()
	var settle: StringName = flutter_clip if aloft else folded_clip
	var change: StringName = unfold_clip if aloft else fold_clip
	_player.speed_scale = flutter_speed if aloft else 1.0
	if animate and _player.has_animation(change):
		_player.play(change, blend)
		_player.queue(settle)
	elif _player.has_animation(settle):
		_player.play(settle, 0.0)


func _find_model() -> CharacterModel:
	var node := get_parent()
	while node:
		if node is CharacterModel:
			return node
		node = node.get_parent()
	return null


static func _find_player(node: Node) -> AnimationPlayer:
	for child in node.get_children():
		if child is AnimationPlayer:
			return child
		var deeper := _find_player(child)
		if deeper:
			return deeper
	return null


# The body's skeleton, never the wings' own.
func _find_skeleton(node: Node) -> Skeleton3D:
	for child in node.get_children():
		if child == self:
			continue
		if child is Skeleton3D:
			return child
		var deeper := _find_skeleton(child)
		if deeper:
			return deeper
	return null
