extends AiTestCase
## The surface grid: ground surfaces of a kind that touch pool into one
## patch, another kind cast over them takes the cells it covers, and
## cells run out one by one.

var GREASE: Ability = load("res://data/abilities/grease.tres")


func run() -> void:
	check("surfaces, clouds and navigation share one cell size",
		SurfaceGrid.CELL == NavigationGrid.CELL_SIZE and CloudGrid.CELL == NavigationGrid.CELL_SIZE)
	var grease: Surface = (GREASE.effects[0] as SpawnSurfaceEffect).surface
	var caster: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(-8.0, 0.0, 0.0))
	var context: WorldContext = WorldManager.context_for(caster)
	var grid: SurfaceGrid = SurfaceManager._grid_for(context)

	var first: SurfacePatch = SurfaceManager.spawn(grease, Vector3(0.0, 0.0, 0.0), 1.5, caster)
	var second: SurfacePatch = SurfaceManager.spawn(grease, Vector3(2.0, 0.0, 0.5), 1.5, caster)
	check("overlapping grease pools into one patch", is_same(first, second) and grid.patches.size() == 1)

	var water := Surface.new()
	water.shape = Surface.Shape.DISC
	SurfaceManager.spawn(water, Vector3(1.0, 0.0, 0.0), 0.6, caster)
	check("water cast over it takes those cells",
		SurfaceManager.surface_at(Vector3(1.0, 0.0, 0.0), context) == water
		and SurfaceManager.surface_at(Vector3(-1.0, 0.0, 0.0), context) == grease)

	var drying: Array[SurfaceCell] = []
	for cell in first.cells:
		if cell.centre().x < 0.0:
			drying.append(cell)
	SurfaceManager.expire_cells(grid, first, drying)
	check("expired cells leave the grid, the rest stay",
		SurfaceManager.surface_at(Vector3(-1.0, 0.0, 0.0), context) == null
		and SurfaceManager.surface_at(Vector3(2.0, 0.0, 0.5), context) == grease)

	SurfaceManager.expire_all_ground(context)
	check("all ground expired: the grid is empty", grid.is_empty())
