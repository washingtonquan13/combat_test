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
	BECOMES, ## The cells turn into `becomes` instead (ice under fire into water), or are cleared away with it unset. The landing surface doesn't land there.
	RESISTS, ## The cells stay as they are and the landing surface doesn't land there (fire on water).
}

@export var element: Surface.Element = Surface.Element.FIRE
@export var outcome: Outcome = Outcome.TAKEN
## What the cells turn into, for BECOMES. Unset clears them.
@export var becomes: Surface
## The reaction runs through every touching cell of this surface, not
## just those the landing surface reached: one spark sets the whole
## grease patch alight, one breath freezes the whole puddle.
@export var spreads: bool = false
