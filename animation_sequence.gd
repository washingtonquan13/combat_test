class_name AnimationSequence
extends Resource
## A composable, ordered sequence of AnimationPlayer clips for one
## ability's cast animation — same "ordered array of small composable
## pieces" shape as VfxEffect/VfxStep, adapted for AnimationPlayer.
##
## Deliberately has NO play() method of its own, unlike VfxEffect. Every
## VfxStep spawns its OWN Tween/particle-instance/audio-player that
## nothing else in the game touches, so VfxEffect.play() can safely be a
## self-contained `for step in steps: await step.play(...)`. Every
## AnimationPhase instead competes for the SAME single AnimationPlayer
## node a unit's hit-reactions/pose/movement clips also call .play() on
## directly and unconditionally — a coroutine suspended awaiting
## animation_finished has no way to notice or recover from something
## else (a hit reaction) replacing the playing clip out from under it;
## AnimationPlayer.play() doesn't fire animation_finished for a clip it
## never let finish, so the coroutine would simply hang forever.
## unit_animator.gd — the node that actually owns the AnimationPlayer —
## owns the sequence position as plain state instead, for exactly this
## reason: state survives an interruption, a suspended await doesn't.
##
## Create instances as .tres files, assign a sequence of AnimationPhase
## resources to phases. Assign the result to Ability.cast_animation (or
## unit_animator.gd's own default_cast_animation fallback) — Jump is
## [Start(ON_FINISH), Loop(EXTERNAL), Land(ON_FINISH)], a Sword Attack
## is just [Sword_Attack(ON_FINISH)], sharing the same phase TYPE
## without either needing bespoke code in the player.

@export var phases: Array[AnimationPhase] = []


func describe() -> String:
	var parts: PackedStringArray = []
	for phase in phases:
		if phase:
			parts.append(phase.describe())
	return " -> ".join(parts)
