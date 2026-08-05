class_name StatusEffect
extends Resource
## Data for one status effect type, composed from independent
## StatusBehavior pieces — see that file's header for why. Create
## instances as .tres files, assign one or more StatusBehavior resources
## to behaviors.

@export var status_name: String = "Status"
@export var icon: Texture2D

## How many of this unit's OWN turns this status lasts, ticked down once
## per turn_start it experiences while active — see StatusManager.
@export var default_duration: int = 3

enum StackMode {
	REFRESH,  ## reapplying resets duration, doesn't add a stack
	STACK,    ## reapplying adds a stack (up to max_stacks) and resets duration
	IGNORE,   ## reapplying while already active does nothing at all
}
@export var stack_mode: StackMode = StackMode.REFRESH
@export var max_stacks: int = 1

@export var behaviors: Array[StatusBehavior] = []

@export_group("Apply FX")
## Optional VFX/SFX played the instant this status is first applied (not
## replayed on a REFRESH/STACK re-application — mirrors StatusBehavior.
## on_apply's own scope, see StatusManager.apply). See unit_vfx.gd/
## unit_sfx.gd, which react to Unit's relayed status_applied signal.
@export var apply_vfx: VfxEffect
@export var apply_sfx: SfxCue

@export_group("Tick FX")
## Optional VFX/SFX played on every on_turn_start tick while active (a
## DamageOverTimeBehavior's per-turn hit, say) — left unset for statuses
## with no turn_start behavior at all, or ones that don't need a
## repeating cue for it.
@export var tick_vfx: VfxEffect
@export var tick_sfx: SfxCue

@export_group("Remove FX")
## Optional VFX/SFX played when this status is removed — expired,
## cured, or replaced. Not played on stack/refresh, only on an actual
## StatusManager.remove() call.
@export var remove_vfx: VfxEffect
@export var remove_sfx: SfxCue


func describe() -> String:
	var lines: PackedStringArray = [status_name]
	for behavior in behaviors:
		var d: String = behavior.describe()
		if d != "":
			lines.append(d)
	return "\n".join(lines)
