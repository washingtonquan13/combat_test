@tool
extends Control

# A 10 cm grid over an orthographic view, on the plane through the origin
# that faces the camera, every 50 cm darker and labelled: a scale to read
# heights, reach and lean off the front, side and top views. Draws nothing
# for a perspective camera.

var camera: Camera3D


func _draw() -> void:
	if camera == null or camera.projection != Camera3D.PROJECTION_ORTHOGONAL:
		return
	var right := _snapped(camera.global_basis.x)
	var up := _snapped(camera.global_basis.y)
	var font := get_theme_default_font()
	for i in range(-20, 21):
		var major := i % 5 == 0
		var c := Color(0, 0, 0, 0.35) if major else Color(0, 0, 0, 0.12)
		var a := camera.unproject_position(right * i * 0.1 + up * -2.0)
		var b := camera.unproject_position(right * i * 0.1 + up * 3.0)
		draw_line(a, b, c, 1.0)
		var d := camera.unproject_position(up * i * 0.1 + right * -3.0)
		var e := camera.unproject_position(up * i * 0.1 + right * 3.0)
		draw_line(d, e, c, 1.0)
		if major:
			draw_string(font, Vector2(4, d.y - 2), "%.1f" % (i * 0.1), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0, 0, 0, 0.6))
			draw_string(font, Vector2(a.x + 2, size.y - 4), "%.1f" % (i * 0.1), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0, 0, 0, 0.6))


static func _snapped(v: Vector3) -> Vector3:
	var best := Vector3.RIGHT
	for axis: Vector3 in [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD]:
		if v.dot(axis) > v.dot(best):
			best = axis
	return best
