@tool
extends Node3D

# The animation lab: one mannequin, the weapons in its hands, and nothing of
# the game. It poses the mannequin from a clip in a library or from the key
# poses a keys script builds, at a time, and draws what an animator checks:
# the centre of mass with its plumb line, the feet's support, the off hand's
# mark on the weapon, and a readout of every joint against its limit (see
# pose_metrics.gd).
#
# In the editor: open anim_lab.tscn, pick the clip or the keys set and the
# weapons in the inspector, scrub `time` or pick a `key`, and look through
# any of the View cameras (each has a Preview toggle). Run it with --out and
# it renders a sheet instead and quits, one row per time, one column per
# view and a column of readout:
#
#   godot --path . --rendering-driver opengl3 --resolution 420x420 \
#     res://tools/anim_lab/anim_lab.tscn -- --out=C:/path/sheet.png \
#     [--clip=Stance_Longgun | --keys=res://tools/anim_lab/rifle_blocking.gd --set=stance] \
#     [--times=0,0.5,1.2 | --at-keys] [--interp=stepped|keyed|flowing] \
#     [--views=front,side,top,quarter,hands] [--main=res://scenes/weapons/rifle.tscn] [--off=...]
#     [--prop=res://world/ladder.tscn]
#
# --prop sets a scene at the mannequin's feet, in its space (+Z ahead): a
# ladder, a ledge, whatever the clip is played against.
#
# Run it with --watch=C:/path/request.json instead and it stays open: each
# time that file changes it reads the same arguments from it as JSON, reloads
# the keys script from disk, renders the sheet to its "out" and writes
# "<out>.done". tools/anim_lab/live.sh drives it.
#
# A keys script extends RefCounted and has build(poses: PoseBuilder) ->
# Dictionary: set name -> {"length", "loops", "keys": [[time, label, pose]]},
# poses as PoseBuilder takes them. The lab interpolates the keys itself so a
# blocking pass can be looked at stepped, every key held, before any
# inbetween exists.

const PoseBuilder := preload("res://tools/pose_builder.gd")
const PoseMetrics := preload("res://tools/anim_lab/pose_metrics.gd")
const BodyVolumes := preload("res://tools/anim_lab/body_volumes.gd")

enum Source { CLIP, KEYS }
enum Interp { STEPPED, KEYED, FLOWING }

const VIEWS := ["front", "side", "top", "quarter", "hands"]
const SKELETON_PATH := "Model/Body/Armature/GeneralSkeleton"
const MAIN_GRIP := "Model/Body/Armature/GeneralSkeleton/MainHand/Grip"
const OFF_GRIP := "Model/Body/Armature/GeneralSkeleton/OffHand/Grip"

@export var source: Source = Source.KEYS:
	set(v):
		source = v
		_dirty = true
@export var library: AnimationLibrary:
	set(v):
		library = v
		_dirty = true
@export var clip: String = "Stance_Longgun":
	set(v):
		clip = v
		_dirty = true
@export var keys_script: Script:
	set(v):
		keys_script = v
		_sets = {}
		_dirty = true
@export var keys_set: String = "stance":
	set(v):
		keys_set = v
		_dirty = true
@export var interp: Interp = Interp.STEPPED:
	set(v):
		interp = v
		_dirty = true
@export_range(0.0, 10.0, 0.01) var time: float = 0.0:
	set(v):
		time = v
		_dirty = true
# A key's index to show held, or -1 for `time`.
@export var key: int = -1:
	set(v):
		key = v
		_dirty = true
@export var main_weapon: PackedScene:
	set(v):
		main_weapon = v
		_weapons_dirty = true
@export var off_weapon: PackedScene:
	set(v):
		off_weapon = v
		_weapons_dirty = true
@export var overlays := true:
	set(v):
		overlays = v
		_dirty = true
# Press to rebuild the keys after editing the keys script.
@export var reload_keys := false:
	set(v):
		_sets = {}
		_poses = null
		_dirty = true

var _dirty := true
var _weapons_dirty := true
var _poses: PoseBuilder
var _sets := {}
var _metrics: PoseMetrics
var _volumes: BodyVolumes
var _report := ""
var _label := ""


func _ready() -> void:
	var model := get_node("Model")
	for hidden: String in ["OutlineMesh", "HighlightMesh"]:
		var n := model.get_node_or_null(hidden)
		if n:
			n.visible = false
	var player: AnimationPlayer = model.get_node_or_null("Body/AnimationPlayer")
	if player:
		player.active = false
	_draw_floor()
	if not Engine.is_editor_hint():
		var args := _args()
		if args.has("watch"):
			_watch.call_deferred(args["watch"])
		elif args.has("out"):
			_capture.call_deferred(args)


func _process(_delta: float) -> void:
	if _weapons_dirty:
		_weapons_dirty = false
		_mount(MAIN_GRIP, main_weapon)
		_mount(OFF_GRIP, off_weapon)
		_dirty = true
	if _dirty:
		_dirty = false
		_refresh()


func _skeleton() -> Skeleton3D:
	return get_node(SKELETON_PATH)


func _mount(grip_path: String, scene: PackedScene) -> void:
	var grip := get_node(grip_path)
	for c in grip.get_children():
		if c.name == "LabWeapon":
			grip.remove_child(c)
			c.free()
	if scene:
		var w := scene.instantiate()
		w.name = "LabWeapon"
		grip.add_child(w)


func _builder() -> PoseBuilder:
	if _poses == null:
		_poses = PoseBuilder.new()
	return _poses


func _keys_set() -> Dictionary:
	if keys_script == null:
		return {}
	if _sets.is_empty():
		_sets = keys_script.new().build(_builder())
	return _sets.get(keys_set, {})


# The resolved pose at t from the keys: held on the key before it, eased
# key to key, or splined through all of them.
func _keys_pose(t: float) -> Dictionary:
	var s := _keys_set()
	if s.is_empty():
		return {}
	var keys: Array = s["keys"]
	var pairs := []
	for k: Array in keys:
		pairs.append([k[0], k[2]])
	var poses := _builder()
	if key >= 0:
		_label = "key %d '%s'" % [mini(key, keys.size() - 1), keys[mini(key, keys.size() - 1)][1]]
		return poses.resolve(keys[mini(key, keys.size() - 1)][2])
	var held := 0
	for i in keys.size():
		if keys[i][0] <= t + 1e-4:
			held = i
	_label = "t %.2f  (%s)" % [t, keys[held][1]]
	match interp:
		Interp.STEPPED:
			return poses.resolve(keys[held][2])
		Interp.KEYED:
			return poses.keyed(t, pairs)
		_:
			return poses.flowing(t, s["length"], pairs, {}, s.get("eased", true))


func _refresh() -> void:
	var skeleton := _skeleton()
	skeleton.reset_bone_poses()
	if source == Source.CLIP:
		_apply_clip(skeleton)
	else:
		_apply_pose(skeleton, _keys_pose(time))
	# The hand attachments follow the skeleton a frame late; the weapon and
	# the contact are read from them now.
	skeleton.force_update_all_bone_transforms()
	for attachment: BoneAttachment3D in skeleton.find_children("*", "BoneAttachment3D", false, false):
		attachment.on_skeleton_update()
	_measure()


func _apply_clip(skeleton: Skeleton3D) -> void:
	_label = "%s  t %.2f" % [clip, time]
	if library == null or not library.has_animation(clip):
		return
	var anim := library.get_animation(clip)
	var t := clampf(time, 0.0, anim.length)
	for i in anim.get_track_count():
		var bone := skeleton.find_bone(String(anim.track_get_path(i).get_concatenated_subnames()))
		if bone < 0:
			continue
		match anim.track_get_type(i):
			Animation.TYPE_ROTATION_3D:
				skeleton.set_bone_pose_rotation(bone, anim.rotation_track_interpolate(i, t))
			Animation.TYPE_POSITION_3D:
				skeleton.set_bone_pose_position(bone, anim.position_track_interpolate(i, t))


func _apply_pose(skeleton: Skeleton3D, pose: Dictionary) -> void:
	if pose.is_empty():
		return
	for bone: String in pose:
		if bone.begins_with("_"):
			continue
		var i := skeleton.find_bone(bone)
		if i >= 0:
			skeleton.set_bone_pose_rotation(i, pose[bone])
	skeleton.set_bone_pose_position(skeleton.find_bone("Hips"), pose["_hips"])


# Where the off hand should be: the main weapon's OffHand marker, if it has
# one and the off hand holds nothing of its own.
func _contact() -> Array:
	var weapon := get_node(MAIN_GRIP).get_node_or_null("LabWeapon")
	if weapon == null or off_weapon != null:
		return []
	var mark: Node3D = weapon.find_child("OffHand", true, false)
	if mark == null:
		return []
	var to_skeleton := _skeleton().global_transform.affine_inverse()
	var off: Node3D = get_node(OFF_GRIP)
	return [to_skeleton * off.global_position, to_skeleton * mark.global_position]


func _measure() -> void:
	if _metrics == null:
		_metrics = PoseMetrics.new(_skeleton())
	if _volumes == null:
		_volumes = BodyVolumes.new(_skeleton(), _body_mesh())
	var contact := _contact()
	var m := _metrics.measure(contact)
	_volumes.set_weapon(get_node(MAIN_GRIP).get_node_or_null("LabWeapon"))
	var clips := _volumes.overlaps()
	m["clips"] = clips
	for c: Dictionary in clips:
		(m["flags"] as Array).append(BodyVolumes.describe(c))
	_report = PoseMetrics.report(m)
	_draw_overlay(m, contact)
	var hands := get_node_or_null("Views/hands")
	if hands:
		var to_world := _skeleton().global_transform
		# The hands apart, one empty: close on the one holding the weapon.
		var one_hand := _metrics.at("RightHand").distance_to(_metrics.at("LeftHand")) > 0.3
		var focus: Vector3 = to_world * (_metrics.at("RightHand") if one_hand
			else _metrics.at("RightHand").lerp(_metrics.at("LeftHand"), 0.5))
		hands.global_position = focus + Vector3(-0.55, 0.3, 0.6).normalized() * (0.6 if one_hand else 1.5)
		hands.look_at(focus, Vector3.UP)


# The skinned body mesh: the one under the skeleton with a skin.
func _body_mesh() -> MeshInstance3D:
	for mi: MeshInstance3D in _skeleton().find_children("*", "MeshInstance3D", true, false):
		if mi.skin != null:
			return mi
	return null


# --- Drawing ---------------------------------------------------------------

func _lines(name_: String, depth_test: bool) -> ImmediateMesh:
	var node: MeshInstance3D = get_node_or_null(name_)
	if node == null:
		node = MeshInstance3D.new()
		node.name = name_
		add_child(node)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.vertex_color_use_as_albedo = true
		mat.no_depth_test = not depth_test
		mat.render_priority = 1 if not depth_test else 0
		node.material_override = mat
		node.mesh = ImmediateMesh.new()
	var mesh: ImmediateMesh = node.mesh
	mesh.clear_surfaces()
	return mesh


func _draw_floor() -> void:
	var mesh := _lines("Floor", true)
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(-10, 11):
		var c := Color(0.3, 0.32, 0.35) if i % 5 == 0 else Color(0.45, 0.47, 0.5)
		for v: Array in [[Vector3(i * 0.1, 0, -1), Vector3(i * 0.1, 0, 1)], [Vector3(-1, 0, i * 0.1), Vector3(1, 0, i * 0.1)]]:
			mesh.surface_set_color(c)
			mesh.surface_add_vertex(v[0])
			mesh.surface_set_color(c)
			mesh.surface_add_vertex(v[1])
	# Forward, +Z: a blue tick.
	mesh.surface_set_color(Color(0.1, 0.3, 1))
	mesh.surface_add_vertex(Vector3(0, 0.002, 1.0))
	mesh.surface_set_color(Color(0.1, 0.3, 1))
	mesh.surface_add_vertex(Vector3(0, 0.002, 1.25))
	mesh.surface_end()


func _draw_overlay(m: Dictionary, contact: Array) -> void:
	var mesh := _lines("Overlay", false)
	if not overlays:
		return
	var to_world := _skeleton().global_transform
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var seg := func(a: Vector3, b: Vector3, c: Color) -> void:
		mesh.surface_set_color(c)
		mesh.surface_add_vertex(to_world * a)
		mesh.surface_set_color(c)
		mesh.surface_add_vertex(to_world * b)
	var cross := func(p: Vector3, r: float, c: Color) -> void:
		for axis: Vector3 in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
			seg.call(p - axis * r, p + axis * r, c)
	# The stick figure, so the bones read through the mesh.
	var bones := _skeleton()
	var stick := Color(1, 0.85, 0.2)
	for i in bones.get_bone_count():
		var p := bones.get_bone_parent(i)
		var n := bones.get_bone_name(i)
		if p <= 0 or n.contains("Index") or n.contains("Ring") or n.contains("Little") or n.contains("leaf"):
			continue
		seg.call(bones.get_bone_global_pose(p).origin, bones.get_bone_global_pose(i).origin, stick)
	# Centre of mass, its plumb line, the support under it.
	var com: Vector3 = m["com"]
	var ok: bool = m["inside"]
	var com_color := Color(0.1, 0.9, 0.2) if ok else Color(1, 0.1, 0.1)
	cross.call(com, 0.05, com_color)
	seg.call(com, Vector3(com.x, 0.0, com.z), com_color)
	cross.call(Vector3(com.x, 0.0, com.z), 0.03, com_color)
	var hull: PackedVector2Array = m["support"]
	for i in hull.size():
		var a := hull[i]
		var b := hull[(i + 1) % hull.size()]
		seg.call(Vector3(a.x, 0.003, a.y), Vector3(b.x, 0.003, b.y), Color(0.1, 0.8, 1))
	if contact.size() == 2:
		cross.call(contact[1], 0.025, Color(1, 0.2, 1))
		seg.call(contact[0], contact[1], Color(1, 0.2, 1))
	# Each clip at its deepest sample.
	for c: Dictionary in m.get("clips", []):
		cross.call(c["at"], 0.04, Color(1, 0, 0))
	mesh.surface_end()


# --- Capture ---------------------------------------------------------------

static func _args() -> Dictionary:
	var out := {}
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			out[kv[0]] = kv[1] if kv.size() > 1 else ""
	return out


func _capture(args: Dictionary) -> void:
	var err := await _render(args)
	get_tree().quit(0 if err == OK else 1)


# Renders each request written to `path` until the lab is closed.
func _watch(path: String) -> void:
	print("anim_lab: watching %s" % path)
	var seen := 0
	while true:
		await get_tree().create_timer(0.1).timeout
		var stamp := FileAccess.get_modified_time(path) if FileAccess.file_exists(path) else 0
		if stamp == seen:
			continue
		seen = stamp
		var args = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not args is Dictionary or not args.has("out"):
			continue
		if args.has("keys"):
			var script: GDScript = load(args["keys"])
			script.source_code = FileAccess.get_file_as_string(args["keys"])
			script.reload()
		_sets = {}
		_poses = null
		var err: Error = await _render(args)
		var done := FileAccess.open(args["out"] + ".done", FileAccess.WRITE)
		done.store_string(error_string(err))
		done.close()


func _render(args: Dictionary) -> Error:
	if args.has("library"):
		library = load(args["library"])
	if args.has("clip"):
		source = Source.CLIP
		clip = args["clip"]
	if args.has("keys"):
		source = Source.KEYS
		keys_script = load(args["keys"])
	if args.has("set"):
		keys_set = args["set"]
	if args.has("interp"):
		interp = Interp[String(args["interp"]).to_upper()]
	if args.has("main"):
		main_weapon = load(args["main"]) if args["main"] != "" else null
	if args.has("off"):
		off_weapon = load(args["off"]) if args["off"] != "" else null
	var old_prop := get_node_or_null("Model/Prop")
	if old_prop:
		old_prop.free()
	if String(args.get("prop", "")) != "":
		var prop: Node = (load(args["prop"]) as PackedScene).instantiate()
		prop.name = "Prop"
		$Model.add_child(prop)
	# Moves every view by x,y,z metres, for a clip that travels out of frame.
	var look := String(args.get("look", "0,0,0")).split_floats(",")
	$Views.position = Vector3(look[0], look[1], look[2])
	var views: PackedStringArray = String(args.get("views", ",".join(VIEWS))).split(",")
	# Rows: the given times, or each key held.
	var rows := []
	if args.has("at-keys"):
		for i in _keys_set().get("keys", []).size():
			rows.append({"key": i, "time": 0.0})
	else:
		for t: String in String(args.get("times", "0")).split(","):
			rows.append({"key": -1, "time": t.to_float()})
	var hud: Label = $Hud/Caption
	var panel: Label = $Hud/Readout
	var size := get_viewport().get_visible_rect().size
	var sheet := Image.create(int(size.x) * (views.size() + 1), int(size.y) * rows.size(), false, Image.FORMAT_RGB8)
	for r in rows.size():
		key = rows[r]["key"]
		time = rows[r]["time"]
		_process(0.0)
		for c in views.size():
			var cam: Camera3D = get_node("Views/" + views[c])
			cam.current = true
			hud.text = "%s   %s" % [views[c], _label]
			panel.visible = false
			$Hud/Grid.camera = cam
			$Hud/Grid.queue_redraw()
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			sheet.blit_rect(_grab(), Rect2i(Vector2i.ZERO, Vector2i(size)), Vector2i(int(size.x) * c, int(size.y) * r))
		hud.text = _label
		panel.text = _report
		panel.visible = true
		$Hud/Grid.camera = null
		$Hud/Grid.queue_redraw()
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		sheet.blit_rect(_grab(), Rect2i(Vector2i.ZERO, Vector2i(size)), Vector2i(int(size.x) * views.size(), int(size.y) * r))
		print("ROW %d %s\n%s" % [r, _label, _report])
	var err := sheet.save_png(args["out"])
	print("anim_lab: wrote %s (%s)" % [args["out"], error_string(err)])
	return err


func _grab() -> Image:
	var img := get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	return img
