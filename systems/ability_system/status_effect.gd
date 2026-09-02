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

@export_group("Animation")
## Optional clip played the instant this status is first applied (same
## first-application-only scope as apply_vfx/apply_sfx — not replayed on
## a REFRESH/STACK re-application) — a plain clip name, not a composable
## resource like VfxEffect/SfxCue, matching how every OTHER animation in
## this project already works (see unit_animator.gd's Clip Names group).
## Meant for a status with a genuinely distinct POSE, not just a
## reaction flourish — see remove_animation below for why the two are a
## pair, not independent fields.
@export var apply_animation: String = ""
## Whether apply_animation is a looping "resting" clip (e.g. a lying-
## down idle) rather than a one-shot that should freeze on its final
## frame once it finishes playing — see unit_animator.gd's
## _rest_on_base_animation, which is the only place this is read.
## Defaults false (freeze on last frame), matching how apply_animation
## already behaved before this field existed — a status only needs to
## touch this if its pose clip is specifically authored to loop.
@export var apply_animation_loops: bool = false
## Optional clip played when this status is actually removed (expired,
## cured, replaced) IF apply_animation ever played and is still being
## held — see unit_animator.gd's Unit.posed_status. Left unset, the
## animator falls back to its own default idle clip instead (rather than
## holding the pose's final frame forever, which is very likely not what
## you want) — but if you set apply_animation for a real pose (lying
## down, frozen, ...) you almost always want a matching, purpose-made
## remove_animation (a recovery clip) too.
@export var remove_animation: String = ""

@export_group("Hit Reaction FX")
## Optional clip/VFX/SFX played instead of the animator's/VFX's/SFX's own
## defaults for a moment where this unit takes damage while this
## status's apply_animation is currently being held (e.g. a "flinch
## while down" clip for Prone/Incapacitate, distinct from a standing
## hit-react) — same shape as Apply/Tick/Remove FX above, just for this
## fourth moment. Left unset, each system plays its own normal default
## reaction instead. Whichever plays, the unit still correctly returns to
## holding this status's pose afterward regardless — that part is
## handled structurally (see Unit.visual_state/posed_status), not
## per-status, so it can't be forgotten by leaving these unset.
@export var hit_reaction_animation: String = ""
@export var hit_reaction_vfx: VfxEffect
@export var hit_reaction_sfx: SfxCue

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
