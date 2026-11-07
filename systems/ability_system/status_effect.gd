@tool
class_name StatusEffect
extends Resource
## Data for one status effect type, composed from independent
## StatusBehavior pieces — see that file's header for why. Create
## instances as .tres files, assign one or more StatusBehavior resources
## to behaviors.
##
## @tool only for the stat-id suggestions on resisted_by
## (_validate_property).

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

## Whether a RemoveStatusEffect (a cure, a dispel) can take this off.
## False for a status the rules own entering and leaving — Downed only
## ends by being picked up, stabilized, or dying.
@export var curable: bool = true

## Statuses in one group are strengths of the same thing - Burning and
## the wall's Searing - and a unit has at most one of them: the higher
## rank replaces a lower one, a lower one never lands over a higher.
## Empty means no group.
@export var group: StringName = &""
@export var rank: int = 0
## Groups this status counters (Pathfinder's "counters and dispels"):
## landing on a unit that has a status of one of these groups removes
## that status instead of applying this one. Enlarged and Reduced counter
## each other, so each cast steps size one way and it never passes +/-1.
## By group, not by StatusEffect, so two statuses can counter each other
## without a resource cycle.
@export var counters: Array[StringName] = []

@export_group("Resistance")
## The stat a target rolls against to shrug this off as it lands — HT
## for Sleep or a weakening, Will for fear, DX for a slip. Empty means
## it always lands: a buff, fire, or a rule status like Downed. Rolled
## only when it comes from something hostile or from nothing at all (a
## surface); an ally's status is never resisted. See
## UnitCombat.resists.
@export var resisted_by: StringName = &""
## Added to the resistance roll; negative makes it harder to shrug off.
@export var resistance_modifier: int = 0

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
## Motion key of the pose the body takes the instant this status is first
## applied (same first-application-only scope as apply_vfx/apply_sfx, not
## replayed on a REFRESH/STACK re-application), resolved to a clip by the
## body's MotionSet. Meant for a status with a genuinely distinct POSE
## (&"knockdown" for Prone), not a reaction flourish. Whether the pose loops
## or freezes on its last frame is the clip's own loop mode. A body with no
## clip for the key simply doesn't pose.
@export var apply_motion: StringName = &""
## Motion key played when this status is actually removed (expired, cured,
## replaced) IF its apply_motion pose is still being held; see
## unit_animator.gd's Unit.posed_status. Empty, or a key the body has no clip
## for, falls back to the body's idle instead of holding the pose's final
## frame forever, but a real pose almost always wants a matching recovery
## (&"get_up").
@export var remove_motion: StringName = &""

@export_group("Hit Reaction FX")
## Optional motion/VFX/SFX played instead of the animator's/VFX's/SFX's own
## defaults when this unit takes damage while this status's apply_motion
## pose is held (a "flinch while down" for Prone, distinct from a standing
## hit-react); same shape as Apply/Tick/Remove FX above, for this fourth
## moment. Left unset, each system plays its own normal default reaction.
## Whichever plays, the unit still returns to holding this status's pose
## afterward; that part is structural (see Unit.visual_state/posed_status),
## not per-status, so it can't be forgotten by leaving these unset.
@export var hit_reaction_motion: StringName = &""
@export var hit_reaction_vfx: VfxEffect
@export var hit_reaction_sfx: SfxCue

@export_group("Remove FX")
## Optional VFX/SFX played when this status is removed — expired,
## cured, or replaced. Not played on stack/refresh, only on an actual
## StatusManager.remove() call.
@export var remove_vfx: VfxEffect
@export var remove_sfx: SfxCue


func _validate_property(property: Dictionary) -> void:
	if property.name == "resisted_by":
		StatDatabase.suggest_ids(property)


func describe() -> String:
	var lines: PackedStringArray = [status_name]
	for behavior in behaviors:
		var d: String = behavior.describe()
		if d != "":
			lines.append(d)
	if resisted_by != &"":
		var modifier: String = "" if resistance_modifier == 0 else " %+d" % resistance_modifier
		lines.append("Resisted by %s%s" % [resisted_by, modifier])
	return "\n".join(lines)
