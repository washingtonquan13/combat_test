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

var _placeholder: Node3D = null
var _label: Label3D = null


func _ready() -> void:
	if Engine.is_editor_hint():
		_build_placeholder()


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


func _get_configuration_warnings() -> PackedStringArray:
	if role_name() == &"":
		return PackedStringArray(["This marker plays no role — name it, or set `role`."])
	return PackedStringArray()
