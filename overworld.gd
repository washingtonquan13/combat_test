extends Node3D
## Greybox SMT-style overworld — a maze generated at _ready() from a text
## layout rather than hand-placed nodes, using proto_block.tscn (already
## a StaticBody3D with a BoxMesh/BoxShape3D, see that file's own header)
## for both walls and the floor slab. Purely a pipeline proof: three
## doors, all leading to test_arena.tscn today, plus the single
## controllable avatar and its follow camera.
##
## '#' wall, '.' floor, 'S' the avatar's very-first spawn point, 'A'/'B'/
## 'C' door tiles — each is both a floor tile AND a trigger that enters
## test_arena, remembering which door was used (WorldManager.
## pending_return_spawn) so the debug exit in esc_menu.gd returns the
## avatar to the same one.

const AVATAR_SCENE: PackedScene = preload("res://overworld_avatar.tscn")
const WALL_SCENE: PackedScene = preload("res://proto_block.tscn")
const TEST_ARENA_SCENE: PackedScene = preload("res://test_arena.tscn")

const CELL_SIZE: float = 2.0
const WALL_HEIGHT: float = 2.0

const LAYOUT: PackedStringArray = [
	"###########",
	"#S.#.....A#",
	"#.#.#.###.#",
	"#.#.#.....#",
	"#.#.#####.#",
	"#.........#",
	"#.#######.#",
	"#B.......C#",
	"###########",
]

@onready var _camera: OverworldCamera = $OverworldCamera
@onready var _geometry: Node3D = $Geometry

var _avatar: OverworldAvatar
var _door_areas: Dictionary = {}  # StringName -> Area3D
var _start_point: Marker3D


func _ready() -> void:
	_build_maze()
	_spawn_avatar()
	_camera.target = _avatar
	_camera.snap_to_target()


func get_base_mode() -> GameMode.Mode:
	return GameMode.Mode.OVERWORLD


## Duck-typed — see WorldManager.load_world()'s own header. The overworld
## holds one avatar, not a spawned tactical party; PartyManager.roster
## stays untouched either way, only whether it gets projected into live
## Units for THIS world varies.
func spawns_party() -> bool:
	return false


func get_tactical_camera() -> Camera3D:
	return _camera


func get_spawn_point(spawn_point_name: StringName) -> Node3D:
	return _door_areas.get(spawn_point_name, _start_point)


func _build_maze() -> void:
	for row in LAYOUT.size():
		var line: String = LAYOUT[row]
		for col in line.length():
			var world_pos := Vector3(col * CELL_SIZE, 0.0, row * CELL_SIZE)
			match line[col]:
				"#":
					_place_wall(world_pos)
				"S":
					_start_point = _place_marker(world_pos)
				"A", "B", "C":
					_place_door(world_pos, line[col])

	_place_floor()


func _place_wall(pos: Vector3) -> void:
	var block: ProtoBlock = WALL_SCENE.instantiate()
	_geometry.add_child(block)
	block.size = Vector3(CELL_SIZE, WALL_HEIGHT, CELL_SIZE)
	block.position = pos + Vector3(0.0, WALL_HEIGHT / 2.0, 0.0)


func _place_floor() -> void:
	var width: float = LAYOUT[0].length() * CELL_SIZE
	var depth: float = LAYOUT.size() * CELL_SIZE
	var block: ProtoBlock = WALL_SCENE.instantiate()
	_geometry.add_child(block)
	block.size = Vector3(width, 1.0, depth)
	block.position = Vector3(width / 2.0 - CELL_SIZE / 2.0, -0.5, depth / 2.0 - CELL_SIZE / 2.0)


func _place_marker(pos: Vector3) -> Marker3D:
	var marker := Marker3D.new()
	_geometry.add_child(marker)
	marker.position = pos
	return marker


## Each door is an Area3D covering its own cell. "primed" (see its own
## metadata) guards against the avatar re-triggering the very door it
## just spawned on top of, returning from test_arena — without this, the
## instant its collider starts overlapping an already-occupied door on
## spawn, body_entered would fire again and bounce straight back. A
## door NOT under the avatar's spawn point starts primed=true (its first
## real approach should trigger normally); _spawn_avatar() below flips
## the ONE matching door to primed=false after placing the avatar, and
## body_exited flips it back the moment the avatar actually walks off it.
func _place_door(pos: Vector3, door_name: String) -> void:
	var door := Area3D.new()
	door.name = "Door" + door_name
	door.set_meta("primed", true)
	_geometry.add_child(door)
	door.position = pos

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(CELL_SIZE, WALL_HEIGHT, CELL_SIZE)
	shape.shape = box
	door.add_child(shape)

	door.body_entered.connect(_on_door_entered.bind(door, StringName(door_name)))
	door.body_exited.connect(_on_door_exited.bind(door))

	_door_areas[StringName(door_name)] = door


func _spawn_avatar() -> void:
	_avatar = AVATAR_SCENE.instantiate()
	_geometry.add_child(_avatar)

	var spawn_name: StringName = WorldManager.pending_return_spawn
	var spawn_point: Node3D = get_spawn_point(spawn_name)
	_avatar.global_position = spawn_point.global_position

	if _door_areas.has(spawn_name):
		_door_areas[spawn_name].set_meta("primed", false)


func _on_door_exited(body: Node3D, door: Area3D) -> void:
	if body is OverworldAvatar:
		door.set_meta("primed", true)


func _on_door_entered(body: Node3D, door: Area3D, door_name: StringName) -> void:
	if not body is OverworldAvatar or not door.get_meta("primed"):
		return
	WorldManager.pending_return_spawn = door_name
	# Deferred, not called directly: body_entered fires from WITHIN the
	# physics server's own callback, and load_world() synchronously frees
	# this exact world — including this door's own CollisionObject3D via
	# WorldManager's remove_child() (see that file's own note on why that
	# has to be synchronous, not deferred, for a different reason: the
	# name-collision bug it was written to fix). Godot explicitly
	# disallows removing a CollisionObject3D mid-physics-callback; calling
	# through call_deferred() runs the actual load at the next idle frame,
	# safely outside physics processing.
	call_deferred("_enter_test_arena")


func _enter_test_arena() -> void:
	WorldManager.load_world(TEST_ARENA_SCENE)
