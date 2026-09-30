class_name PassiveSkillPrerequisite
extends PrerequisiteRule
## A skill check that resolves itself once, silently, the first time
## it's evaluated — never a player-clicked, dice-popup roll like
## SkillCheckChoice. The result is cached forever via FlagManager under
## flag_name: the cache-hit path returns the stored VALUE (get_flag),
## not just whether the key exists (has_flag) — a failed roll still
## writes the flag, so existence alone can't distinguish "already
## rolled and failed" from "never rolled," and FlagPrerequisite (built
## for flags that are only ever set to true) can't stand in as the gate
## for that reason. One class, directly usable as DialogueChoice.
## prerequisites, so which mechanism gates a choice is visible from
## that one resource's own script type — no second resource to cross-
## reference to know it involves a roll at all.
##
## is_satisfied() writing on a cache miss is a real departure from
## every sibling PrerequisiteRule (all pure reads) — deliberately kept
## anyway rather than split into a separate action step: a conversation
## only ever calls is_satisfied_in() once per choice, synchronously, from
## _show_node()'s own filter loop, so there's no speculative or
## concurrent call path for the write to race against. Splitting it out
## traded a real bug (see above) and a less discoverable data shape for
## a purity guarantee this codebase doesn't currently need. If a second,
## speculative call site (a preview, a debug tool) is ever added, that
## tradeoff needs revisiting — don't call this from one without
## rechecking this comment.
##
## flag_name must be unique per passive check, same authoring discipline
## DialogueChoice.sets_flag already requires.

@export var skill_name: String = ""
@export var flag_name: String = ""


func is_satisfied(unit: Unit) -> bool:
	return _check(unit, null)


## Inside a conversation the roll uses that conversation's own dice, so a
## test that pins the seed pins this roll too.
func is_satisfied_in(c: Conversation) -> bool:
	return _check(c.cast.get("player") as Unit, c.rng)


func _check(unit: Unit, rng: RandomNumberGenerator) -> bool:
	if FlagManager.has_flag(flag_name):
		return FlagManager.get_flag(flag_name)

	var result: SkillCheckResult = SkillCalculator.get_skill_level(unit, skill_name)
	var passed: bool = result.can_use_skill and unit.roll_vs(result.skill_level, rng).success
	FlagManager.set_flag(flag_name, passed)
	return passed
