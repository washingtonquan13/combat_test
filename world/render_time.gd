class_name RenderTime
extends SubViewport
## What shaders read as TIME this frame, known on the CPU.
##
## Godot keeps no API for the renderer's clock, and it doesn't advance
## exactly as the frame deltas the game sees (a long hitch clamps the
## process delta, not the render step). So a 2x1 viewport draws TIME and a
## frame number into its pixels, a readback every READ seconds returns the
## pair, and the gap between that TIME and the summed deltas of that frame
## corrects the estimate. Until the first readback lands, now() is -1.

## Seconds between readbacks.
const READ := 0.5
## Frames of summed deltas kept, longer than a readback takes to land.
const HISTORY := 64

var _rect := ColorRect.new()
var _material := ShaderMaterial.new()
var _frame := 0
var _sum := 0.0
var _sums := PackedFloat64Array()
var _offset := 0.0
var _known := false
var _since := READ
var _reading := false
var _rollover := 3600.0


func _init() -> void:
	size = Vector2i(2, 1)
	disable_3d = true
	use_hdr_2d = true
	render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_material.shader = preload("res://world/render_time.gdshader")
	_rect.material = _material
	_rect.size = Vector2(2, 1)
	add_child(_rect)
	_sums.resize(HISTORY)
	_rollover = ProjectSettings.get_setting("rendering/limits/time/time_rollover_secs", 3600.0)
	# Before the nodes that ask for now() in their own _process.
	process_priority = -100


func _process(delta: float) -> void:
	_frame += 1
	_sum += delta
	_sums[_frame % HISTORY] = _sum
	_material.set_shader_parameter(&"frame", float(_frame))
	_since += delta
	if _since >= READ and not _reading:
		_since = 0.0
		_reading = true
		var texture := RenderingServer.texture_get_rd_texture(get_texture().get_rid())
		RenderingServer.call_on_render_thread(func() -> void:
			var rd := RenderingServer.get_rendering_device()
			if rd.texture_get_data_async(texture, 0, _on_read) != OK:
				_reading = false)


## TIME in shaders this frame, or -1 while it isn't known yet.
func now() -> float:
	return fposmod(_sum + _offset, _rollover) if _known else -1.0


func _on_read(data: PackedByteArray) -> void:
	_reading = false
	# RGBA16F: 8 bytes a pixel, each channel one byte of the value.
	if data.size() < 16:
		return
	var time := _decode(data, 0)
	var frame := int(_decode(data, 8))
	if frame <= 0 or frame > _frame or _frame - frame >= HISTORY:
		return
	_offset = time - _sums[frame % HISTORY]
	_known = true


func _decode(data: PackedByteArray, at: int) -> float:
	var bytes := PackedByteArray()
	bytes.resize(4)
	for i in 4:
		bytes[i] = int(data.decode_half(at + i * 2))
	return bytes.decode_float(0)
