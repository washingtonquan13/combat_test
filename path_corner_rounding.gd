class_name PathCornerRounding
extends RefCounted
## Static utility: replaces each interior vertex of a polyline with a
## small quadratic-Bezier fillet, so real grid-aligned turns don't read
## as jagged 90/45-degree corners. Same algorithm movement_indicator.gd
## already uses for its own path preview (as a private method there,
## kept that way rather than refactored to call this — that file is
## already shipped/user-tuned, and this pure function needed zero
## changes to lift out, so touching it wasn't worth the risk). Shared
## here instead of duplicated a THIRD time between PathedProjectileStep
## and seeking_indicator.gd, which both need the identical geometry.
##
## Radius is clamped per-corner to at most half of either adjacent
## segment's length, so short zigzag segments can't produce overlapping
## arcs. Endpoints are always kept exact.


static func round_corners(points: PackedVector3Array, radius: float, arc_segments: int) -> PackedVector3Array:
	if points.size() < 3 or radius <= 0.0:
		return points

	var result := PackedVector3Array()
	result.append(points[0])

	for i in range(1, points.size() - 1):
		var prev: Vector3 = points[i - 1]
		var corner: Vector3 = points[i]
		var next: Vector3 = points[i + 1]

		var to_prev: Vector3 = corner - prev
		var to_next: Vector3 = next - corner
		var len_prev: float = to_prev.length()
		var len_next: float = to_next.length()
		if len_prev < 0.001 or len_next < 0.001:
			result.append(corner)
			continue

		var r: float = min(radius, len_prev * 0.5, len_next * 0.5)
		var arc_start: Vector3 = corner - (to_prev / len_prev) * r
		var arc_end: Vector3 = corner + (to_next / len_next) * r

		result.append(arc_start)
		for s in range(1, arc_segments):
			var t: float = float(s) / float(arc_segments)
			var a: Vector3 = arc_start.lerp(corner, t)
			var b: Vector3 = corner.lerp(arc_end, t)
			result.append(a.lerp(b, t))
		result.append(arc_end)

	result.append(points[points.size() - 1])
	return result
