class_name SurfaceReaction
extends Resource
## What a surface on the ground does when a surface of some element lands
## on it: BG3's combos (fire ignites grease, fire melts ice into water,
## cold freezes water, water puts out fire). Listed on the surface being
## landed ON (Surface.reactions), keyed by the element of the one landing
## (Surface.element), and read by SurfaceManager._land.
##
## Without one, the landing surface simply takes the cells over, the
## grid's ordinary rule: one surface per cell, the latest wins. That
## already gives "water on fire puts it out" and "ice over water", so a
## reaction is only needed to change it.

enum Outcome {
	TAKEN,   ## The landing surface takes the cells, as without a reaction; with spreads, every touching cell of this surface too (fire through a grease patch).
	BECOMES, ## The cells turn into `becomes` instead (ice under fire into water), or are cleared away with it unset; a cloud `becomes` rises off them and clears them (water under fire into steam). The landing surface doesn't land there.
	RESISTS, ## The cells stay as they are and the landing surface doesn't land there (fire on water).
}

@export var element: Surface.Element = Surface.Element.FIRE
@export var outcome: Outcome = Outcome.TAKEN
## What the cells turn into, for BECOMES: a Surface .tres. Unset clears
## them. A cloud (a SPHERE or WALL) rises off them instead, its
## wall_height tall over each cell, and they are cleared. A path, not the Surface itself, because reactions run both ways
## (ice melts into water, water freezes into ice) and Godot can't load
## two resource files that refer to each other; this one is loaded the
## first time it's needed, from the cache, so it is the same Surface
## every other reference to that file holds.
@export_file("*.tres") var becomes: String = ""
## The reaction runs through every touching cell of this surface, not
## just those the landing surface reached: one spark sets the whole
## grease patch alight, one breath freezes the whole puddle.
@export var spreads: bool = false


## The Surface the cells turn into, or null to clear them (see becomes).
func becomes_surface() -> Surface:
	return load(becomes) as Surface if not becomes.is_empty() else null
