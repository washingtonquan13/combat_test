class_name AiBehavior
extends Resource
## One composable AI decision rule. CombatAI._decide_action() tries a
## unit's ai_behaviors in order and uses the first one that resolves to
## a real (ability, target) pair — same "ordered array, first satisfied
## entry wins" shape as Unit.dialogue_options/DialogueRootOption. Only
## answers WHO to target and WHAT ability to use; range/approach is
## handled entirely by CombatAI's existing standoff/retry loop
## afterward; a behavior should never check range itself, same as the
## hardcoded baseline it replaces never did (UnitQuery.nearest_hostile
## picks by pure distance, not reachability).

## Returns {} if this behavior doesn't apply right now (no valid
## target); otherwise {"ability": Ability, "target": Unit}. Override in
## each subclass.
func resolve(unit: Unit) -> Dictionary:
	return {}
