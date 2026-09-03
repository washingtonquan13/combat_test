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

## Roughly a person, so an author laying out a shot sees bodies rather than
## three-axis crosses. Editor-only and NEVER SAVED — added without an
## owner, which is what keeps it out of the .tscn.
const PLACEHOLDER_HEIGHT: float = 2.0
const PLACEHOLDER_RADIUS: float = 0.35
const PLACEHOLDER_NAME: StringName = &"__StageRolePlaceholder"

var _placeholder: MeshInstance3D = null


func _ready() -> void:
	if Engine.is_editor_hint():
		_build_placeholder()


## The role this marker plays, falling back to its node name.
func role_name() -> StringName:
	return role if role != &"" else StringName(name)


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

	_placeholder = MeshInstance3D.new()
	_placeholder.name = PLACEHOLDER_NAME
	_placeholder.mesh = capsule
	_placeholder.material_override = material
	# Feet on the marker, which is where a mark means. A capsule's origin
	# is its middle, so it rises by half its height.
	_placeholder.position = Vector3(0.0, PLACEHOLDER_HEIGHT * 0.5, 0.0)
	# No owner is set on purpose: an unowned child is not packed, so the
	# whitebox exists in the editor viewport and in no saved file.
	add_child(_placeholder)


func _get_configuration_warnings() -> PackedStringArray:
	if role_name() == &"":
		return PackedStringArray(["This marker plays no role — name it, or set `role`."])
	return PackedStringArray()
