class_name VfxEffect
extends Resource
## A composable visual/audio effect sequence — combine VfxStep pieces
## into a sequence, same composition philosophy Ability already uses for
## AbilityTargeting/AbilityEffect. Steps run IN ORDER, each one awaited
## to completion before the next starts — a ProjectileStep genuinely
## blocks a following SpawnParticleStep from firing until the travel
## animation finishes, without either step needing to know the other
## exists.
##
## Create instances as .tres files, assign a sequence of step resources.
## Assign the result to an Ability's impact_vfx field to give that
## specific ability its own distinct sequence — a Fireball can be
## [ProjectileStep, SpawnParticleStep, PlaySoundStep] while a Sword
## Attack is just [PlaySoundStep], sharing whichever step TYPES apply
## without either ability needing bespoke code.

@export var steps: Array[VfxStep] = []


## Plays every step in order. context is a live, PERSISTENT Node
## providing tree access for steps that need to spawn children or create
## Tweens (this Resource has none of its own) — pass the scene root, not
## the caster or target Unit, since either combatant could die and be
## freed mid-sequence (a projectile step's Tween is bound to whatever
## node created it; if that node gets queue_free()'d, the Tween dies
## with it, cutting the visual off mid-flight). ability/caster are
## passed through to every step — see VfxStep.play's doc comment.
func play(context: Node, from: Vector3, to: Vector3, ability: Ability = null, caster: Unit = null) -> void:
	for step in steps:
		if step:
			await step.play(context, from, to, ability, caster)
