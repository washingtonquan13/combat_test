extends Node
## Grass baseline bench (docs/plans/bg3_grass_proposal.md, change 0).
##
## Loads the quarry terrain (terrain.scn, which holds the Grass node) with the
## quarry's environment and sun, renders it into a 1920 x 1080 SubViewport
## with TAA on, and at each reference camera station of section 5.1:
##   - GPU render time of that viewport with Grass shown and hidden, in
##     alternating blocks, averaged over many frames;
##   - primitives and draw calls in the frame, with and without grass;
##   - an overdraw count: grass swapped for an unshaded additive copy of its
##     own shader (same vertex code, so the same fold and sink), drawn over a
##     black ground into an HDR buffer, so each pixel holds its layer count.
##     Once with the alpha scissor kept ("covered"), once without ("cards",
##     the fill the rasteriser pays before discard);
##   - a screenshot with grass and one of the layer map.
## Prints a table and quits. Run windowed (GPU timing needs a real device):
##   godot --path <project> res://tools/quarry/grass_bench.tscn -- <out_dir>

const TERRAIN := "res://world/goblin_quarry/terrain.scn"
const ENV := "res://world/goblin_quarry/quarry_environment.tres"
const SIZE := Vector2i(1920, 1080)
## The main field (densest 12 m grass tiles, around the player's start) and
## the quarry camera's own yaw (looking toward -Z).
const ANCHOR := Vector2(-4.0, 30.0)
const FOCUS_OFFSET := 1.0
const FOV := 75.0
## Distance and downward pitch per station. The pitch is crpg_camera.gd's:
## 30 degrees at 5 m rising linearly to 65 at 25 m and holding.
const STATIONS := [["A", 8.0, 35.25], ["B", 25.0, 65.0], ["C", 60.0, 65.0]]
const WARMUP := 90
const FRAMES := 300
const BLOCKS := 2

var out_dir := "user://grass_bench"
var sv: SubViewport
var cam: Camera3D
var grass: Node3D
var terrain: Node3D


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0]
	DirAccess.make_dir_recursive_absolute(out_dir)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	get_window().size = Vector2i(480, 270)
	_run.call_deferred()


func _build() -> void:
	sv = SubViewport.new()
	sv.size = SIZE
	sv.own_world_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.use_taa = ProjectSettings.get_setting("rendering/anti_aliasing/quality/use_taa", false)
	sv.msaa_3d = ProjectSettings.get_setting("rendering/anti_aliasing/quality/msaa_3d", 0)
	sv.screen_space_aa = ProjectSettings.get_setting("rendering/anti_aliasing/quality/screen_space_aa", 0)
	add_child(sv)
	terrain = load(TERRAIN).instantiate()
	sv.add_child(terrain)
	grass = terrain.get_node("Grass")
	var we := WorldEnvironment.new()
	we.environment = load(ENV)
	sv.add_child(we)
	# The quarry scene's sun, as world/goblin_quarry.tscn sets it.
	var sun := DirectionalLight3D.new()
	sun.transform = Transform3D(Basis(Vector3(0.469472, 0, 0.882948), Vector3(0.543597, 0.788011, -0.289036), Vector3(-0.695772, 0.615662, 0.369949)), Vector3(0, 10, 0))
	sun.light_color = Color(1, 0.93, 0.8)
	sun.light_energy = 2.3
	sun.light_volumetric_fog_energy = 1.4
	sun.shadow_enabled = true
	sun.shadow_opacity = 0.92
	sun.shadow_blur = 1.5
	sun.directional_shadow_max_distance = 75.0
	sv.add_child(sun)
	cam = Camera3D.new()
	cam.fov = FOV
	cam.far = 400.0
	sv.add_child(cam)
	cam.current = true
	RenderingServer.viewport_set_measure_render_time(sv.get_viewport_rid(), true)


func _ground_y(p: Vector2) -> float:
	# Mean height of the grass roots near p: the clumps sit on the ground.
	var sum := 0.0
	var n := 0
	for c in grass.get_children():
		var mm: MultiMesh = (c as MultiMeshInstance3D).multimesh
		for i in mm.instance_count:
			var o := mm.get_instance_transform(i).origin
			if Vector2(o.x, o.z).distance_to(p) < 1.5:
				sum += o.y
				n += 1
	return sum / n if n > 0 else 0.0


func _place(dist: float, pitch_deg: float, ground: float) -> void:
	var focus := Vector3(ANCHOR.x, ground + FOCUS_OFFSET, ANCHOR.y)
	var pitch := deg_to_rad(pitch_deg)
	cam.position = focus + Vector3(0.0, sin(pitch), cos(pitch)) * dist
	cam.look_at(focus, Vector3.UP)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _sample(n: int) -> Array:
	var rid := sv.get_viewport_rid()
	var gpu := PackedFloat32Array()
	var cpu := PackedFloat32Array()
	for i in n:
		await get_tree().process_frame
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
		cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(rid))
	return [gpu, cpu]


func _render_info() -> Dictionary:
	var rid := sv.get_viewport_rid()
	var vis := RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE
	var sh := RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW
	return {
		"prims": RenderingServer.viewport_get_render_info(rid, vis, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME),
		"draws": RenderingServer.viewport_get_render_info(rid, vis, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME),
		"objects": RenderingServer.viewport_get_render_info(rid, vis, RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME),
		"shadow_prims": RenderingServer.viewport_get_render_info(rid, sh, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME),
	}


static func _mean(a: PackedFloat32Array) -> float:
	var s := 0.0
	for v in a:
		s += v
	return s / maxf(a.size(), 1)


static func _median(a: PackedFloat32Array) -> float:
	var b := a.duplicate()
	b.sort()
	return b[b.size() / 2] if b.size() > 0 else 0.0


func _measure_time() -> Dictionary:
	var on_g := PackedFloat32Array()
	var off_g := PackedFloat32Array()
	var on_c := PackedFloat32Array()
	var off_c := PackedFloat32Array()
	var info_on := {}
	var info_off := {}
	for b in BLOCKS:
		for state in [true, false]:
			grass.visible = state
			await _frames(WARMUP)
			var r: Array = await _sample(FRAMES)
			if state:
				on_g.append_array(r[0])
				on_c.append_array(r[1])
				info_on = _render_info()
			else:
				off_g.append_array(r[0])
				off_c.append_array(r[1])
				info_off = _render_info()
	grass.visible = true
	return {
		"gpu_on": _mean(on_g), "gpu_off": _mean(off_g),
		"gpu_on_med": _median(on_g), "gpu_off_med": _median(off_g),
		"cpu_on": _mean(on_c), "cpu_off": _mean(off_c),
		"info_on": info_on, "info_off": info_off,
	}


# ------------------------------------------------------------ overdraw

var _od_mats := {}
var _od_env: Environment
var _black: ShaderMaterial


func _overdraw_shader(src: String) -> Shader:
	# The grass shader with its render mode and fragment replaced: same
	# uniforms and vertex code, so cards fold and sink exactly as in the game.
	var lines := src.split("\n")
	for i in lines.size():
		if lines[i].begins_with("render_mode"):
			lines[i] = "render_mode cull_disabled, unshaded, blend_add, depth_draw_never, fog_disabled;"
			break
	var code := "\n".join(lines)
	var at := code.find("void fragment()")
	code = code.substr(0, at) + """uniform bool od_scissor = true;
void fragment() {
	vec2 uv = (cell + clamp(UV, vec2(0.01), vec2(0.99))) / atlas_grid;
	vec4 t = texture(tufts, uv);
	if (od_scissor && t.a < 0.5) {
		discard;
	}
	ALBEDO = vec3(1.0);
	ALPHA = 1.0;
}
"""
	var sh := Shader.new()
	sh.code = code
	return sh


func _od_material(src: ShaderMaterial, scissor: bool) -> ShaderMaterial:
	var key := [src.get_instance_id(), scissor]
	if _od_mats.has(key):
		return _od_mats[key]
	var m := ShaderMaterial.new()
	m.shader = _overdraw_shader(src.shader.code)
	for u in src.shader.get_shader_uniform_list():
		m.set_shader_parameter(u.name, src.get_shader_parameter(u.name))
	m.set_shader_parameter("od_scissor", scissor)
	_od_mats[key] = m
	return m


func _overdraw_setup(on: bool, scissor: bool) -> void:
	if _od_env == null:
		_od_env = Environment.new()
		_od_env.background_mode = Environment.BG_COLOR
		_od_env.background_color = Color.BLACK
		_od_env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		_od_env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
		_black = ShaderMaterial.new()
		_black.shader = Shader.new()
		_black.shader.code = "shader_type spatial;\nrender_mode unshaded;\nvoid fragment() { ALBEDO = vec3(0.0); }\n"
	cam.environment = _od_env if on else null
	sv.use_hdr_2d = on
	sv.use_taa = false if on else ProjectSettings.get_setting("rendering/anti_aliasing/quality/use_taa", false)
	if not on:
		# Put back exactly what was there: the bake sets the ground's material
		# as an override, so clearing it would leave the ground white.
		for g in _saved:
			g[0].set(g[1], g[2])
		_saved.clear()
		return
	for c in terrain.get_children():
		if c == grass:
			continue
		# Only the ground occludes in the count; props and trees are hidden.
		if c.name == "Ground":
			for g in c.find_children("*", "GeometryInstance3D", true, false):
				_swap(g, "material_override", _black)
		elif c is Node3D:
			_swap(c, "visible", false)
	for c in grass.get_children():
		var mmi := c as MultiMeshInstance3D
		var src: ShaderMaterial = mmi.multimesh.mesh.surface_get_material(0)
		_swap(mmi, "material_override", _od_material(src, scissor))


var _saved := []


func _swap(o: Object, prop: String, value: Variant) -> void:
	_saved.append([o, prop, o.get(prop)])
	o.set(prop, value)


func _overdraw(name: String, scissor: bool) -> Dictionary:
	_overdraw_setup(true, scissor)
	await _frames(30)
	var img := sv.get_texture().get_image()
	var fmt := img.get_format()
	img.convert(Image.FORMAT_RF)
	var f := img.get_data().to_float32_array()
	var sum := 0.0
	var covered := 0
	var mx := 0.0
	var vis := PackedByteArray()
	vis.resize(f.size())
	for i in f.size():
		var v := f[i]
		sum += v
		if v > 0.5:
			covered += 1
		mx = maxf(mx, v)
		vis[i] = int(clampf(v * 8.0, 0.0, 255.0))
	var map := Image.create_from_data(img.get_width(), img.get_height(), false, Image.FORMAT_L8, vis)
	map.save_png(out_dir.path_join("layers_%s_%s.png" % [name, "covered" if scissor else "cards"]))
	_overdraw_setup(false, scissor)
	return {
		"mean_frame": sum / f.size(),
		"mean_grass": sum / maxf(covered, 1),
		"share": float(covered) / f.size(),
		"max": mx,
		"format": fmt,
	}


func _expected_tris() -> int:
	# A cross-check of the primitive counter: triangles of every grass chunk
	# inside the frustum and its visibility range, counted from the meshes.
	var planes := cam.get_frustum()
	var tris := 0
	for c in grass.get_children():
		var mmi := c as MultiMeshInstance3D
		var box := mmi.global_transform * mmi.get_aabb()
		if cam.global_position.distance_to(box.get_center()) > mmi.visibility_range_end:
			continue
		var inside := true
		for pl in planes:
			var far_pt := box.position + Vector3(box.size.x if pl.normal.x < 0 else 0.0, box.size.y if pl.normal.y < 0 else 0.0, box.size.z if pl.normal.z < 0 else 0.0)
			if pl.is_point_over(far_pt):
				inside = false
				break
		if not inside:
			continue
		var m := mmi.multimesh.mesh
		tris += mmi.multimesh.instance_count * (m.surface_get_array_index_len(0) / 3)
	return tris


# ------------------------------------------------------------ run

func _run() -> void:
	_build()
	var ground := _ground_y(ANCHOR)
	print("bench: anchor %s ground %.2f, %d grass nodes" % [ANCHOR, ground, grass.get_child_count()])
	_place(25.0, 65.0, ground)
	await _frames(300)
	var rows := []
	for st in STATIONS:
		_place(st[1], st[2], ground)
		await _frames(WARMUP)
		var t: Dictionary = await _measure_time()
		t["expected"] = _expected_tris()
		await _frames(10)
		sv.get_texture().get_image().save_png(out_dir.path_join("station_%s.png" % st[0]))
		grass.visible = false
		await _frames(10)
		sv.get_texture().get_image().save_png(out_dir.path_join("station_%s_nograss.png" % st[0]))
		grass.visible = true
		var od_cov: Dictionary = await _overdraw(st[0], true)
		var od_cards: Dictionary = await _overdraw(st[0], false)
		await _frames(30)
		rows.append([st, t, od_cov, od_cards])
		print("bench: station %s done (%s)" % [st[0], cam.position])

	print("")
	print("GRASS BENCH  %dx%d  TAA %s  %s" % [SIZE.x, SIZE.y, sv.use_taa, RenderingServer.get_video_adapter_name()])
	print("st | dist pitch | GPU on  off  grass (median grass) ms | CPU on off ms | prims on  off  grass | draws on off grass | shadow prims on off | expected grass tris | layers covered: frame / on-grass / share | layers cards: frame / on-grass / share | max")
	for r in rows:
		var st: Array = r[0]
		var t: Dictionary = r[1]
		var a: Dictionary = r[2]
		var b: Dictionary = r[3]
		var on: Dictionary = t.info_on
		var off: Dictionary = t.info_off
		print("%s | %.0f m %.1f | %.2f %.2f %.2f (%.2f) | %.2f %.2f | %d %d %d | %d %d %d | %d %d | %d | %.2f / %.2f / %.0f%% | %.2f / %.2f / %.0f%% | %.0f / %.0f" % [
			st[0], st[1], st[2],
			t.gpu_on, t.gpu_off, t.gpu_on - t.gpu_off, t.gpu_on_med - t.gpu_off_med,
			t.cpu_on, t.cpu_off,
			on.prims, off.prims, on.prims - off.prims,
			on.draws, off.draws, on.draws - off.draws,
			on.shadow_prims, off.shadow_prims, t.expected,
			a.mean_frame, a.mean_grass, a.share * 100.0,
			b.mean_frame, b.mean_grass, b.share * 100.0,
			a.max, b.max])
	print("overdraw image format %s (expect half float)" % rows[0][2].format)
	get_tree().quit()
