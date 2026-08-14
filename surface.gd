class_name Surface
extends Resource
## Data for one surface TYPE (Fire, Grease, Poison Cloud, ...) that can be
## spawned onto the battlefield — the world-anchored counterpart to
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

@export var surface_name: String = "Surface"
## How many ROUNDS (a full pass through turn order — see
## CombatManager.round_started) this surface persists before expiring on
## its own. -1 means permanent — it never ages out via round tick and has
## to be cleared some other way (a future dispel effect, say).
@export var duration_rounds: int = 3
## Vertical extent (meters) of the Area3D collision shape SurfaceManager
## builds for this surface (see SurfaceManager.spawn) — centered so it
## reaches from ground level up to this height, tall enough to reliably
## overlap a unit's own collision shape regardless of minor ground
## unevenness. Purely a detection volume, not a visual — has nothing to
## do with ambient_scene's own size.
@export var detection_height: float = 2.0
## Applied to a unit the MOMENT it physically enters the surface's Area3D
## (see SurfaceManager.spawn/_on_body_entered) — punishes the actual
## movement decision, mid-turn, rather than waiting for a turn boundary —
## and again at the START of any turn a unit is still standing inside it
## (see SurfaceManager._on_turn_started), which is what keeps it applied
## turn after turn for someone who just stands there without triggering
## a fresh entry event. Left unset, the surface exists visually but does
## nothing mechanically.
@export var status_effect: StatusEffect

@export_group("Movement")
## Multiplies the BUDGET cost (not the visual walking speed) of
## physically crossing this surface — 2.0 means every meter walked
## through it costs 2 meters of move_remaining, the standard "difficult
## terrain" rule most tactics games use. 1.0 (the default) means no
## effect at all. Read via SurfaceManager.movement_cost_multiplier_at,
## which PathAvoidance.simulate_path samples DURING route planning
## itself (see that function's cost_sampler param) — baked into the plan
## up front rather than applied separately during the real walk, which
## is what guarantees the movement preview and the actual move can never
## disagree about it (see path_avoidance.gd's own header for why that
## guarantee matters generally).
@export var movement_cost_multiplier: float = 1.0

@export_group("Visual")
## Persistent looping visual instantiated once when the surface spawns
## and freed when it expires (see SurfaceManager.spawn/_expire) —
## deliberately distinct from VfxEffect/VfxStep, which model a one-shot
## sequence that plays to completion and is done; a surface's ambient
## look instead needs to just sit there for the surface's entire
## lifetime. Any scene works as long as it doesn't try to free itself —
## SurfaceManager owns that.
@export var ambient_scene: PackedScene
## Whether ambient_scene's horizontal (X/Z) scale is stretched to match
## the surface's actual spawned radius, same reasoning and same default
## (no vertical stretch — height_scale_factor is implicitly 0 here) as
## SpawnParticleStep.scale_to_ability_radius.
@export var scale_ambient_to_radius: bool = true
## The radius ambient_scene was authored at 1.0x scale for — only
## matters if scale_ambient_to_radius is on.
@export var authored_radius: float = 1.0

@export_group("Spawn/Expire FX")
## Optional one-shot VFX/SFX for the instant the surface appears or
## expires — reuses VfxEffect/SfxCue exactly like every other one-shot
## moment in the project (Ability's cast_vfx, StatusEffect's apply/
## remove FX, ...).
@export var spawn_vfx: VfxEffect
@export var spawn_sfx: SfxCue
@export var expire_vfx: VfxEffect
@export var expire_sfx: SfxCue


func describe() -> String:
	var lines: PackedStringArray = [surface_name]
	if status_effect:
		lines.append("Applies %s while standing in it" % status_effect.status_name)
	return "\n".join(lines)
