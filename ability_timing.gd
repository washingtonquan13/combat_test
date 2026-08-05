class_name AbilityTiming
extends Resource
## Optional, composable timing profile for abilities that have a
## genuinely distinct "launch, then something travels/resolves, then
## impact" shape — a projectile, a melee swing synced to an animation's
## connect frame. NOT every ability has this shape: a self-buff, a
## passive toggle, an instant heal cast on an ally standing next to you
## — none of these have anything resembling "impact" as a separate
## moment from "use." Forcing every Ability to carry waits_for_impact/
## impact_timeout/impact_sfx fields regardless, sitting unused at their
## defaults for anything that isn't a projectile or synced melee attack,
## is exactly the flat-field-on-every-instance problem this project has
## repeatedly moved away from via composition — AbilityTargeting/
## AbilityEffect, StatusEffect/StatusBehavior, VfxEffect/VfxStep all
## exist for this same reason.
##
## Assign this to Ability.timing ONLY for abilities that actually have
## launch/impact as meaningfully separate moments. Leave it unset for
## anything else — an ability with no AbilityTiming resolves its effects
## the instant it's confirmed to happen (the same as waits_for_impact
## always being false), with zero timing-related fields cluttering its
## own resource for a concept that was never relevant to it in the
## first place.

## If true, UnitCombat.use_ability() waits for Unit.notify_impact() —
## called by an attack animation's Call Method Track (placed at the
## frame a weapon actually connects), or a VFX sequence's
## ImpactSignalStep (typically right after a projectile arrives) —
## before actually applying this ability's effects.
@export var waits_for_impact: bool = false
## Safety timeout — if notify_impact() never arrives (the animation/VFX
## isn't actually wired up to call it, despite waits_for_impact being
## on), effects apply anyway after this many seconds rather than the
## ability hanging forever and stalling the whole turn.
@export var impact_timeout: float = 3.0
## Optional composable sound (see SfxCue) played at the impact moment —
## see unit_sfx.gd, which reacts to Unit.impact_triggered directly.
@export var impact_sfx: SfxCue
