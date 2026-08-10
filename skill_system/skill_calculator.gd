class_name SkillCalculator
extends RefCounted
## Computes an effective skill level and usability for a unit. Stateless
## — every function takes its full input as parameters and returns a
## fresh result, same convention as PlayerInteractionState (this project's
## other static-utility RefCounted) rather than an autoload; nothing here
## needs to persist between calls or live in the scene tree.
##
## Two-tier lookup, preserving the original design's actual goal (a unit
## only stores skills it has ACTUALLY trained, never a slot for every
## skill that exists in the game): first check whether the unit has a
## learned SkillInstance for this name; if not, fall back to
## SkillDatabase to see whether the skill is usable via default anyway.
## A learned skill's own skill_data is used directly rather than also
## being re-resolved through SkillDatabase — the original version did
## both unconditionally, which was redundant at best and a correctness
## risk at worst if the two ever disagreed.

## A skill may default through at most one OTHER skill's own default
## chain (GURPS' double-defaulting limit) — depth=0 is the skill actually
## being asked about, depth=1 is one default hop away, depth>1 is refused
## outright rather than chaining further.
const MAX_DEFAULT_DEPTH: int = 1
## GURPS' Rule of 20 — a default's SOURCE value is capped here before the
## rule's own modifier is added, so an absurdly high source (e.g. a
## default off a skill that itself defaulted very high) can't produce an
## unbounded chain of ever-larger numbers.
const RULE_OF_20_CAP: int = 20


static func get_skill_level(unit: Unit, skill_name: String, depth: int = 0) -> SkillCheckResult:
	if depth > MAX_DEFAULT_DEPTH:
		return SkillCheckResult.new(0, false)

	var instance: SkillInstance = _find_instance(unit, skill_name)
	var skill_data: Skill = instance.skill_data if instance else SkillDatabase.find(skill_name)
	if not skill_data:
		return SkillCheckResult.new(0, false)

	var trained_level: int = 0
	if instance:
		trained_level = instance.get_relative_skill_level(unit.get_attribute_value(skill_data.controlling_attribute))

	# Seeded at trained_level (0 if unlearned) rather than an out-of-band
	# sentinel — a default only ever raises this, so "no default found"
	# and "no default beat the trained level" both naturally leave it
	# unchanged, with no magic number standing in for either case.
	var best_level: int = trained_level
	var has_valid_default: bool = false
	for rule in skill_data.defaults:
		var source: Dictionary = _resolve_default_source(unit, rule, depth)
		if not source.found:
			continue
		has_valid_default = true
		var adjusted: int = min(source.value, RULE_OF_20_CAP) + rule.modifier
		if adjusted > best_level:
			best_level = adjusted

	var is_usable: bool = (
		instance != null
		or has_valid_default
		or (not skill_data.learned_only and not skill_data.defaults.is_empty())
	)
	return SkillCheckResult.new(best_level, is_usable)


## {found: bool, value: int} — found=false means this particular default
## source didn't resolve to anything usable (an ATTRIBUTE source always
## resolves; a SKILL source doesn't if that skill itself isn't usable,
## including via the depth cutoff above). Same {found, ...} shape
## NavigationGrid.nearest_valid_point already uses elsewhere in this
## project for "did this specific query turn up something," not a new
## convention invented for this file.
static func _resolve_default_source(unit: Unit, rule: DefaultRule, depth: int) -> Dictionary:
	match rule.source_type:
		DefaultRule.SourceType.ATTRIBUTE:
			return {"found": true, "value": unit.get_attribute_value(rule.source_name)}
		DefaultRule.SourceType.SKILL:
			var result: SkillCheckResult = get_skill_level(unit, rule.source_name, depth + 1)
			return {"found": result.can_use_skill, "value": result.skill_level}
	return {"found": false, "value": 0}


static func _find_instance(unit: Unit, skill_name: String) -> SkillInstance:
	for instance in unit.skills:
		if instance.skill_data.skill_name == skill_name:
			return instance
	return null
