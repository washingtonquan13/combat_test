# Navigation authoring contract

What level geometry has to look like for `NavigationGrid` (gdextension/src/navigation_grid.cpp) to see it the way physics does. The grid is baked from the scene tree, not from physics queries, so anything the bake does not read is invisible to pathing even if units collide with it.

## What counts as geometry
- A `CollisionShape3D` that is a **direct child** of a `StaticBody3D` (`collect_static_shapes`). A shape nested deeper, for example under a plain Node3D inside the body, is not read.
- The body must be on at least one collision layer. A body with `collision_layer == 0` collides with nothing and is skipped. The project defines no separate world-geometry layer (units, props and level share layer 1), so any layer counts.
- `CollisionShape3D.disabled` shapes are skipped, as are shapes with no Shape resource.
- The bake is a snapshot taken at the first query after `NavigationGrid.invalidate()`. Geometry that moves must call `invalidate()` when it settles; movable_prop.gd does this on every drop.

## Ignored
- `AnimatableBody3D` (it moves; the bake cannot follow it), `RigidBody3D`, `CharacterBody3D`, `Area3D`.
- `CSGShape3D` nodes and `GridMap`. Give such a level a StaticBody3D with real shapes, or bake the mesh into a ConcavePolygonShape3D.
- Ladders have no collision of their own; their ends are ordinary geometry.

## Shapes
| Shape | How it is rasterized |
|---|---|
| Box, Sphere, Cylinder, Capsule | exactly, cell by cell inside the shape's own bounding box; a tilted box no steeper than 45.5 degrees is a ramp |
| ConcavePolygonShape3D | as its triangles |
| ConvexPolygonShape3D with 4 to 160 points | as its hull's triangles |
| HeightMapShape3D | as its triangles |
| anything else (WorldBoundary, SeparationRay, a convex hull over 160 points, ...) | filled as its whole bounding box, with one warning per shape in the output |

## Closed and open meshes
Triangle shapes are rasterized as shells: faces flatter than walkable become ground, steeper faces mark the cells they pass through. What lies inside a shell is decided by one rule, below, so a mesh does not need to be closed to be solid underneath. But a mesh that is open (a missing face, a hole, a gap between pieces wider than a cell) is open in the grid too: the outside flows in through the gap and the space inside stays walkable air. Close meshes that are meant to be solid, or overlap the pieces.

## What "inside" means
An open cell is air only if it connects to the outside through face-adjacent open cells. The grid's bounds are the geometry's bounding box plus a margin of air, and that margin is the outside. Every open cell the outside cannot reach becomes solid, for walking, flying, clearance and connectivity alike (`seal_interiors`, run once per bake).

So:
- The inside of a closed mesh, a box built from overlapping boxes, or a hollow rock is solid.
- A room with walls and a roof and no opening is solid inside too. A room meant to be entered needs an opening, at least one cell (0.25 m) wide; a unit needs a much wider one to walk through.
- A crack that only a diagonal step gets through does not count as an opening. No unit fits through it anyway.

Cost: every chunk a shape touches is rasterized at the bake rather than lazily, and labelled by runs of open cells. A chunk no shape touches costs one node. Run Godot with `--verbose` to see the chunk counts, the cells sealed and the time it took.
