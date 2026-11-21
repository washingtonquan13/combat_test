@tool
class_name StageRole
extends Marker3D
## A body on the timeline. One of these per role a stage stages.
##
## WHY A MARKER AND NOT THE UNIT ITSELF. The obvious design is to put the
## actor under the stage and key its transform directly — and it is wrong
## twice over. A Unit is a CharacterBody3D that belongs to the world it was
## spawned in: reparenting one into a cutscene takes it out of the
## navigation grid's occupancy, out of its encounter, out of the World3D
## every world-scoped query asks about, and the scene then has to put all
## of that back correctly on every exit path including an abort. UNITS ARE
## NEVER REPARENTED BY A STAGE. The marker moves; the actor is copied onto
## it.
##
## And the timeline has to exist before the cast does. A stage is authored
## against roles — "leader", "parent_a" — that resolve to different units
## on every play and to nothing at all in the editor. A marker is the thing
## that can be keyed at authoring time and pointed at a person at runtime.
##
## THE FLAG IS WHICH WAY THE COPY GOES, and both directions are needed:
##
##   drives_actor = true    the marker is the authority. Every frame the
##                          actor is put where the marker is, so "place on
##                          a mark" and "slide between two marks" are
##                          ordinary keyed transforms on this node.
##   drives_actor = false   the actor is the authority. bind() snaps the
##                          marker onto it once, so a FramingRig aiming at
##                          this role has something to point at in the
##                          editor and the runtime shot still follows the
##                          living, walking unit through the cast.
##
## The arrival scene uses false: the player's leader has just arrived under
## their own power and a cutscene that yanked them onto a mark would undo
## the arrival it is there to celebrate.

## Which cast role this marker stands in for. Defaults to the node's own
## name, so a node called "leader" needs nothing set — the name IS the
## authoring surface, and a role typed twice is a role that can disagree
## with itself.
@export var role: StringName = &"":
	set(value):
		role = value
		update_configuration_warnings()
## See the header. False by default because "follow the person" is the
## commoner case and the safer one: a stage that drives an actor it should
## not have owns that actor's position for the whole scene.
@export var drives_actor: bool = false
## Who plays this role in the editor preview. The stand-in wears this
## unit's body (its look's body_scene, else its model_scene) instead of the
## capsule, and the beats pose it: a ClipBeat's clip, a paired action's two
## clips, the walk while a walk beat moves it, the idle otherwise. So a shot
## is framed on a person in the pose they will be in, not on a tube.
##
## Editor only. At runtime the role is whoever the scene is handed; this is
## never read. Scripts on the body do not run in the editor, so it shows
## undressed: no look, no hair, no held weapon, no face.
@export var preview_unit: UnitDefinition = null:
	set(value):
		preview_unit = value
		if Engine.is_editor_hint() and is_inside_tree():
			_build_preview_model()

## Roughly a person, so an author laying out a shot sees bodies rather
## than three-axis crosses. Editor-only and NEVER SAVED — added without an
## owner, which is what keeps it out of the .tscn.
##
## THE STAND-IN, NOT THE MARKER, IS WHAT A PREVIEW MOVES. A beat previewing
## a walk or a spawn has to move and hide a body while the timeline is
## scrubbed, and the marker's own transform is saved into the .tscn — a
## preview that moved the marker would rewrite the scene every time
## someone scrubbed and saved. The stand-in is an unowned Node3D at the
## marker's feet with the capsule under it; the stage resets it before
## each preview pass (reset_preview) and beats move stand_in() only.
const PLACEHOLDER_HEIGHT: float = 2.0
const PLACEHOLDER_RADIUS: float = 0.35
const PLACEHOLDER_NAME: StringName = &"__StageRolePlaceholder"
## Where a previewed line floats, above the stand-in's head.
const LABEL_HEIGHT: float = PLACEHOLDER_HEIGHT + 0.4
const CAPSULE_NAME: StringName = &"Capsule"
const MODEL_NAME: StringName = &"__PreviewModel"
## A body's HEAD anchor when it declares none, as a share of its height:
## CharacterModel._fallback_ratio(HEAD). The runtime frames a role there.
const HEAD_RATIO: float = 0.85
## CharacterModel.height's default, for a body that sets none.
const DEFAULT_HEIGHT: float = 2.0

var _placeholder: Node3D = null
var _label: Label3D = null
var _model: Node3D = null
var _player: AnimationPlayer = null
## What the beats asked this preview pass: a clip and the seconds into it.
## A later beat's ask wins, as a later clip does at runtime.
var _pending_clip: String = ""
var _pending_at: float = 0.0


func _ready() -> void:
	if Engine.is_editor_hint():
		_build_placeholder()
		_build_preview_model()


## The role this marker plays, falling back to its node name.
func role_name() -> StringName:
	return role if role != &"" else StringName(name)


## Where an editor preview READS this role from — the preview camera
## framing it: the stand-in, or the marker itself when there is none (at
## runtime, or in a headless tool). Read-only; see stand_in() for writing.
func preview_body() -> Node3D:
	return _placeholder if is_instance_valid(_placeholder) else self


## The stand-in alone, or null when there is none. What a BEAT previews
## on: unlike preview_body() it never falls back to the marker, because a
## beat moving the marker would be moving something saved.
func stand_in() -> Node3D:
	return _placeholder if is_instance_valid(_placeholder) else null


## A line of text over the stand-in's head, for a previewed LineBeat. Made
## on first use, unowned like the stand-in, and hidden by reset_preview().
## Null when there is no stand-in.
func preview_label() -> Label3D:
	if not is_instance_valid(_placeholder):
		return null
	if is_instance_valid(_label):
		return _label
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.pixel_size = 0.004
	_label.width = 600.0
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.position = Vector3(0.0, LABEL_HEIGHT, 0.0)
	_placeholder.add_child(_label)
	return _label


## Puts the stand-in back on the marker, shown, with nothing said. Called
## by the stage before every preview pass, so a preview is a function of
## the time alone.
func reset_preview() -> void:
	if not is_instance_valid(_placeholder):
		return
	_placeholder.transform = Transform3D.IDENTITY
	_placeholder.visible = true
	paint_stand_in(Color(0, 0, 0, 0))
	if is_instance_valid(_label):
		_label.visible = false
	_pending_clip = ""
	_pending_at = 0.0


## A beat's preview asking for `clip`, `seconds` into it. Nothing is posed
## until pose_preview(), after every beat has had its say.
func preview_clip(clip: String, seconds: float) -> void:
	_pending_clip = clip
	_pending_at = seconds


## Poses the preview body on what the beats asked for, or on its idle at
## the timeline time `now` when nothing did. Called by the stage after
## every beat's preview. A looping clip wraps; a one-shot holds its ends.
## A clip the body does not have leaves it in its last pose.
func pose_preview(now: float) -> void:
	if not is_instance_valid(_player):
		return
	var clip: String = _pending_clip
	var at: float = _pending_at
	if clip == "":
		clip = preview_idle_clip()
		at = now
	if clip == "":
		return
	if not _player.has_animation(clip):
		_player = _find_player()  # a reload can leave the old pick cached
		if not is_instance_valid(_player) or not _player.has_animation(clip):
			return
	var animation: Animation = _player.get_animation(clip)
	if animation.loop_mode != Animation.LOOP_NONE and animation.length > 0.0:
		at = fposmod(at, animation.length)
	else:
		at = clampf(at, 0.0, animation.length)
	if _player.assigned_animation != clip:
		_player.assigned_animation = clip
	_player.seek(at, true)


## The preview body, or null when the stand-in is the capsule.
func preview_model() -> Node3D:
	return _model if is_instance_valid(_model) else null


## The preview body's standing and walking clips ("" with no body).
func preview_idle_clip() -> String:
	return _model_text(&"idle_animation")


func preview_walk_clip() -> String:
	return _model_text(&"walk_animation")


## Where the runtime frames this role: its body's HEAD anchor
## (CharacterModel.anchor_position). In the editor that is the skeleton's
## Head bone, so it follows the pose; a body with no Head bone falls back on
## a share of its height. The capsule stands for a body of the default
## height.
func preview_head() -> Vector3:
	var body: Node3D = preview_body()
	var model: Node3D = preview_model()
	if model == null:
		return body.global_position + Vector3.UP * DEFAULT_HEIGHT * HEAD_RATIO
	var declared: Variant = model.get(&"head_anchor")
	var anchor: Node3D = null
	if declared is Node3D:
		anchor = declared
	elif declared is NodePath and not (declared as NodePath).is_empty():
		anchor = model.get_node_or_null(declared) as Node3D
	if anchor:
		return anchor.global_position
	# In the editor the body's script does not run, so it has no sockets;
	# its Head bone is where the runtime's head socket sits.
	var skeleton: Skeleton3D = model.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var bone: int = skeleton.find_bone("Head") if skeleton else -1
	if bone >= 0:
		return skeleton.global_transform * skeleton.get_bone_global_pose(bone).origin
	var height: Variant = model.get(&"height")
	var tall: float = float(height) if (height is float or height is int) else DEFAULT_HEIGHT
	return model.global_position + Vector3.UP * tall * model.global_basis.get_scale().y * HEAD_RATIO


## A SilhouetteBeat's preview: the stand-in painted one flat colour. A
## fully transparent colour takes the paint off.
func paint_stand_in(paint_color: Color) -> void:
	if not is_instance_valid(_placeholder):
		return
	var paint: Material = null if paint_color.a <= 0.0 else SilhouetteBeat.overlay_for(paint_color)
	for mesh in _placeholder.find_children("*", "MeshInstance3D", true, false):
		(mesh as MeshInstance3D).material_overlay = paint


func _build_placeholder() -> void:
	if is_instance_valid(_placeholder):
		return
	var capsule := CapsuleMesh.new()
	capsule.height = PLACEHOLDER_HEIGHT
	capsule.radius = PLACEHOLDER_RADIUS

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.65, 0.72, 0.85, 0.45)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var mesh := MeshInstance3D.new()
	mesh.name = CAPSULE_NAME
	mesh.mesh = capsule
	mesh.material_override = material
	# Feet on the marker, which is where a mark means. A capsule's origin
	# is its middle, so it rises by half its height.
	mesh.position = Vector3(0.0, PLACEHOLDER_HEIGHT * 0.5, 0.0)

	_placeholder = Node3D.new()
	_placeholder.name = PLACEHOLDER_NAME
	_placeholder.add_child(mesh)
	# No owner is set on purpose: an unowned child is not packed, so the
	# stand-in exists in the editor viewport and in no saved file.
	add_child(_placeholder)


## The preview_unit's body under the stand-in, turned by its unit's facing
## offset as a unit turns its model, with the capsule hidden. Unowned like
## the stand-in, so never saved.
func _build_preview_model() -> void:
	if not is_instance_valid(_placeholder):
		return
	if is_instance_valid(_model):
		_placeholder.remove_child(_model)
		_model.free()
	_model = null
	_player = null
	var scene: PackedScene = _preview_scene()
	if scene:
		_model = scene.instantiate() as Node3D
	if _model:
		_model.name = MODEL_NAME
		_model.rotation.y = deg_to_rad(_facing_offset())
		_placeholder.add_child(_model)
		_player = _find_player()
	var capsule: Node3D = _placeholder.get_node_or_null(NodePath(CAPSULE_NAME)) as Node3D
	if capsule:
		capsule.visible = _model == null


func _preview_scene() -> PackedScene:
	if preview_unit == null:
		return null
	var look: Variant = preview_unit.get(&"look")
	if look is Resource:
		var path: Variant = (look as Resource).get(&"body_scene")
		if path is String and path != "" and ResourceLoader.exists(path):
			var body: PackedScene = load(path) as PackedScene
			if body:
				return body
	return preview_unit.get(&"model_scene") as PackedScene


## The unit's facing_offset_degrees as its scene sets it: a model facing
## +Z is turned half round so it faces the way the unit does.
func _facing_offset() -> float:
	var scene: Variant = preview_unit.get(&"unit_scene") if preview_unit else null
	if scene is PackedScene:
		var state: SceneState = (scene as PackedScene).get_state()
		for i in state.get_node_property_count(0):
			if state.get_node_property_name(0, i) == &"facing_offset_degrees":
				return float(state.get_node_property_value(0, i))
	return 0.0


## The model's player with the most clips; the named one wins a tie. In
## the editor an imported body can bring its own AnimationPlayer (one
## RESET clip), which takes the name and pushes the model's real one to
## "AnimationPlayer2", so the NodePath lands on the wrong one.
func _find_player() -> AnimationPlayer:
	var path: Variant = _model.get(&"animation_player")
	var named: AnimationPlayer = null
	if path is AnimationPlayer:
		named = path
	elif path is NodePath and not (path as NodePath).is_empty():
		named = _model.get_node_or_null(path) as AnimationPlayer
	var best: AnimationPlayer = named
	var most: int = named.get_animation_list().size() if named else 0
	for node in _model.find_children("*", "AnimationPlayer", true, false):
		var count: int = (node as AnimationPlayer).get_animation_list().size()
		if count > most:
			most = count
			best = node as AnimationPlayer
	return best


func _model_text(property: StringName) -> String:
	var value: Variant = _model.get(property) if is_instance_valid(_model) else null
	return value if value is String else ""


func _get_configuration_warnings() -> PackedStringArray:
	if role_name() == &"":
		return PackedStringArray(["This marker plays no role — name it, or set `role`."])
	return PackedStringArray()
