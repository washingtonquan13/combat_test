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
## Applied to any unit standing inside the surface at the START of that
## unit's own turn (see SurfaceManager._on_turn_started) — the same
## checkpoint StatusManager.tick_turn_start() already runs at, just
## checked from the surface's side instead of the unit's. Left unset, the
## surface exists visually but does nothing mechanically.
@export var status_effect: StatusEffect

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
## moment in the project (Ability's impact_vfx, StatusEffect's apply/
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
