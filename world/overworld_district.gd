class_name OverworldDistrict
extends Area3D
## One named place on the overworld, for the area label. Its shape is its
## CollisionPolygon3D children, which the editor draws and lets you drag
## point by point; tools/blockout/districts.py writes the first version.
##
## An Area3D only so the editor has a polygon to show and edit: it does
## no physics (no layers, not monitoring). The overworld asks it whether
## a point is inside, a few times a second, instead.

## The name the area label shows.
@export var display_name: String = ""

var _area: float = -1.0


## Whether p (world space) is inside any piece, seen from above: a
## piece's depth is ignored.
func has_point(p: Vector3) -> bool:
	for piece in _pieces():
		var local: Vector3 = piece.global_transform.affine_inverse() * p
		if Geometry2D.is_point_in_polygon(Vector2(local.x, local.y), piece.polygon):
			return true
	return false


## Square metres of all pieces, so where two districts overlap the
## smaller one, drawn inside the larger, wins.
func area() -> float:
	if _area < 0.0:
		_area = 0.0
		for piece in _pieces():
			var poly := piece.polygon
			var twice := 0.0
			for i in poly.size():
				twice += poly[i].cross(poly[(i + 1) % poly.size()])
			_area += absf(twice) * 0.5
	return _area


func _pieces() -> Array[CollisionPolygon3D]:
	var out: Array[CollisionPolygon3D] = []
	for child in get_children():
		if child is CollisionPolygon3D:
			out.append(child)
	return out
