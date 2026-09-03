class_name SkillCheckResult
extends RefCounted
## Small, stable value object returned by SkillCalculator.get_skill_level()
## — a computed roll target plus whether it's actually usable. Kept as a
## typed RefCounted rather than a Dictionary (unlike bigger, more
## heterogeneous result bags elsewhere in this project) since these fields
## are always together — dot-notation access on a known shape reads better
## than dictionary keys for something this small.

var skill_level: int
var can_use_skill: bool
## True only when a SkillInstance backs this result — the unit actually
## trained this skill, as opposed to reaching skill_level via a default
## (or not reaching it at all). Added 2026-09 alongside attemptable below
## for DialogueFormat's untrained-skills-show-a-level rework: rendering
## needs to tell "trained" apart from "usable via default" even though
## can_use_skill is true for both.
var is_trained: bool
## Strictly narrower than can_use_skill — true only when skill_level is
## actually BACKED by something real (training, or a default source that
## genuinely resolved). False in the one gap can_use_skill's own third
## OR-clause leaves open (see SkillCalculator.get_skill_level): a skill
## that's merely not learned_only and has SOME defaults authored, but
## none of them resolved for this unit. In that gap can_use_skill is
## still true (SkillCheckChoice still lets the roll happen, at an honest
## floor of 0) but skill_level carries zero information — printing it as
## a real number would be exactly the lie the old "untrained" word was
## trying to avoid, just reintroduced. DialogueFormat checks this, not
## can_use_skill, before it ever prints a number.
var attemptable: bool


func _init(initial_skill_level: int = 0, initial_can_use_skill: bool = false,
		initial_is_trained: bool = false, initial_attemptable: bool = false) -> void:
	skill_level = initial_skill_level
	can_use_skill = initial_can_use_skill
	is_trained = initial_is_trained
	attemptable = initial_attemptable
