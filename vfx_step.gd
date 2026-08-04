class_name VfxStep
extends Resource
## Base class for one piece of a composable VFX sequence (see VfxEffect)
## — spawn a particle burst, play a sound, wait, animate a projectile
## traveling between two points. Same composition philosophy as
## AbilityEffect: small, reusable, single-purpose pieces combined into a
## sequence, rather than one flat "explosion effect" class trying to
## cover every possible VFX shape.
##
## play() is an async coroutine — anything that takes real time (a
## Tween, a timer) uses `await` internally. VfxEffect awaits each step
## in turn, so a step representing something with genuine duration (a
## projectile actually flying) truly blocks the NEXT step from starting
## until it's done, without VfxEffect needing to know anything about how
## long any given step takes.
##
## context is a live, persistent Node (see VfxEffect.play's doc comment
## for why it should be the scene root, not either combatant) used
## purely for tree access — spawning children, creating Tweens — since a
## Resource has no tree presence of its own to do either.
##
## Steps must not store any per-play state as instance fields (only
## configuration @export values) — this Resource can be shared and
## played concurrently by multiple simultaneous effects (two fireballs
## cast at once, sharing the same VfxEffect resource), and instance
## field state would leak between those unrelated plays. Local variables
## inside play() are safe (each call gets its own stack frame); fields
## on self are not.

## from/to are the caster's and target's positions at the moment the
## WHOLE sequence started, not re-evaluated per step — a step doesn't
## need to know which step number it is or where in the sequence it
## sits, just the two points the sequence is playing between.
func play(_context: Node, _from: Vector3, _to: Vector3) -> void:
	pass


## Human-readable summary for tooltips/editor clarity. Override in each
## subclass.
func describe() -> String:
	return ""
