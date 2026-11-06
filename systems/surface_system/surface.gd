class_name Surface
extends Resource
## Data for one area TYPE (Fire, Grease, Fog Cloud, ...) that can be
## spawned onto the battlefield. BG3's two kinds are one resource with a
## shape: a SURFACE is a flat disc on the ground, a CLOUD a sphere that
## can hang in the air (see shape). Everything else — the status, the
## lifetime, the world it lives in — is the same either way — the world-anchored counterpart to
## StatusEffect (which is unit-anchored). Create instances as .tres files,
## assign to a SpawnSurfaceEffect on an ability with AreaTargeting (see
## that effect's header for why radius isn't a field here).
##
## What a surface DOES to a unit standing in it is deliberately just an
## existing StatusEffect, not a new bespoke mechanic — "standing in Fire"
## is "has the Burning status while inside, same as being lit on fire any
## other way." This reuses StatusManager/StatusBehavior entirely; a
## surface only decides WHO gets the status and for how long the surface
## itself persists, never what the status actually does once applied.
##
## Affects every unit inside regardless of faction — deliberately no
## affects_hostiles/affects_allies split like AreaDamageEffect has. A
## surface is an environmental hazard, not an attack; your own Fire patch
## burning your own units standing in it is the point, not a bug to guard
## against.

## What a surface is made of, for combos (see element, SurfaceReaction).
## Kept apart from damage's WoundType, which has no cold or lightning.
enum Element { NONE, FIRE, COLD, WATER, LIGHTNING }

@export var surface_name: String = "Surface"
## How many ROUNDS (a full pass through turn order — see
## CombatManager.round_started) this surface persists before expiring on
## its own. -1 means permanent — it never ages out via round tick and has
## to be cleared some other way (a future dispel effect, say).
@export var duration_rounds: int = 3

enum Shape {
	DISC,   ## spilled over the ground's SurfaceGrid cells within the radius, merging with its own kind (Grease)
	SPHERE, ## CloudGrid cubes flooded out from the center within the radius, stopped by walls; may be in the air (Fog)
	WALL,   ## CloudGrid cubes standing along a line on the ground, wall_height tall (Wall of Fire; LineTargeting)
}
@export var shape: Shape = Shape.DISC
## How tall a SPHERE stands against its width: below 1 it is squashed
## into a flat ellipsoid, the way fog lies low and spreads wide. The
## radius is its half-width.
@export var height_scale: float = 1.0
## How tall a WALL stands from the ground, in meters.
@export var wall_height: float = 4.0
## A ground surface (a DISC) left on the floor under this cloud's cubes
## as they run out, where they touched it — Wall of Fire's burning
## ground.
@export var leaves_behind: Surface
## Lays leaves_behind under the cubes touching the floor the moment the
## cloud rises, lasting while it stands and its own rounds after, rather
## than only as it runs out. A unit in both is still set burning once:
## SurfaceManager rolls each status once, and of a group only the
## strongest (StatusEffect.group).
@export var lays_ground_under: bool = false
## Applied to a unit the MOMENT it physically enters the surface — a
## DISC's cells under its footprint, a SPHERE's cubes around its body
## (see SurfaceManager._process) — punishes the actual
## movement decision, mid-turn, rather than waiting for a turn boundary —
## and again at the START of any turn a unit is still standing inside it
## (see SurfaceManager._on_turn_started), which is what keeps it applied
## turn after turn for someone who just stands there without triggering
## a fresh entry event. Left unset, the surface exists visually but does
## nothing mechanically.
@export var status_effect: StatusEffect

## The status lasts only while the unit is inside: it comes off when
## they leave (or the area goes) unless another such area still holds
## them. Fog's Blinded. Off, it runs its own duration like Grease's
## Slipped.
@export var status_only_inside: bool = false

@export_group("Reactions")
## What this surface is made of, for combos with what's already on the
## ground (see SurfaceReaction): Fire is FIRE, Ice COLD, Water WATER.
## Grease is NONE: it doesn't do anything to other surfaces, it is
## something fire does something to (its reactions).
@export var element: Element = Element.NONE
## What happens to this surface when one of an element lands on it,
## one entry per element. An element not listed simply takes the cells
## over.
@export var reactions: Array[SurfaceReaction] = []

@export_group("Sight")
## Blocks every sight line that passes through it — into, out of, or
## across (BG3's Fog Cloud). Read by LineOfSight, so ranged targeting,
## AoE aiming and detection all see the same wall.
@export var blocks_sight: bool = false
## It is darkness (Darkness, not Fog): a unit with Dark Vision sees
## through it and is not given its status inside.
@export var dark_vision_sees_through: bool = false

@export_group("Movement")
## Multiplies the BUDGET cost (not the visual walking speed) of
## physically crossing this surface — 2.0 means every meter walked
## through it costs 2 meters of move_remaining, the standard "difficult
## terrain" rule most tactics games use. 1.0 (the default) means no
## effect at all. Read via SurfaceManager.movement_cost_multiplier_at,
## which RoutePlanner.plan samples DURING route planning itself (see
## that function's cost_sampler param) — baked into the plan up front
## rather than applied separately during the real walk, which is what
## guarantees the movement preview and the actual move can never
## disagree about it.
@export var movement_cost_multiplier: float = 1.0

@export_group("Visual")
## Persistent looping visual instantiated once when the surface spawns
## and freed when it expires (see SurfaceManager.spawn), drawn to the surface's cells or cubes —
## deliberately distinct from VfxEffect/VfxStep, which model a one-shot
## sequence that plays to completion and is done; a surface's ambient
## look instead needs to just sit there for the surface's entire
## lifetime. Any scene works as long as it doesn't try to free itself —
## SurfaceManager owns that.
@export var ambient_scene: PackedScene

@export_group("Spawn/Expire FX")
## Optional one-shot VFX/SFX for the instant the surface appears or
## expires — reuses VfxEffect/SfxCue exactly like every other one-shot
## moment in the project (Ability's cast_vfx, StatusEffect's apply/
## remove FX, ...).
@export var spawn_vfx: VfxEffect
@export var spawn_sfx: SfxCue
@export var expire_vfx: VfxEffect
@export var expire_sfx: SfxCue


## This surface's reaction to one of `incoming` landing on it, or null.
func reaction_to(incoming: Element) -> SurfaceReaction:
	if incoming == Element.NONE:
		return null
	for reaction in reactions:
		if reaction and reaction.element == incoming:
			return reaction
	return null


func describe() -> String:
	var lines: PackedStringArray = [surface_name]
	if status_effect:
		lines.append("Applies %s while standing in it" % status_effect.status_name)
	return "\n".join(lines)
