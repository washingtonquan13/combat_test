class_name AiBehavior
extends Resource
## One composable AI decision rule. AiScorer.best_plan() pools every
## candidate a unit's own ai_behaviors propose alongside its baseline
## attack-ability enumeration (see that file's own header) and picks
## whichever scores highest overall — behaviors CONTRIBUTE candidates,
## they don't short-circuit the decision the way this class's old
## resolve()-returns-first-match contract did. That old contract had a
## real, confirmed flaw: a healer with both an attack and a heal
## authored would heal a 49%-HP ally instead of finishing a 5%-HP enemy,
## because the heal behavior, tried first, simply won by being first.
## Under scoring, both are candidates and the better one wins.
##
## A behavior only needs to say WHICH (ability, target) pairs it thinks
## are worth considering, and — optionally, via AiPlan.score — how much
## it wants to bias toward them beyond what the shared scorer's own
## expected-damage/expected-heal arithmetic would already say (see
## AiScorer._score_plan, which adds its own tactical value ON TOP of
## whatever a behavior sets here, rather than a behavior needing to
## duplicate that math itself). Leaving score at its default 0.0 means
## "let the shared arithmetic decide entirely" — the common case; only
## set it to express a genuine authored preference (a boss favoring its
## signature move) or an urgency signal a plain damage/heal number can't
## capture on its own.
##
## Range/approach is still handled entirely by AiScorer/CombatAI's
## existing standoff/reach machinery — a behavior should never check
## range itself, same as before. The one exception: a behavior may set
## AiPlan.destination directly (via with_destination) when it needs to
## express WHERE to stand independent of any ability's own approach
## range — see the flight positioning behaviors (MaintainAltitude,
## Swoop, ...), which is exactly the case the old {ability, target}
## dictionary contract had no room for at all.

## Returns every candidate this behavior thinks unit could reasonably
## take right now — empty if none apply (no valid target, a required
## resource unauthored, ...). Override in each subclass.
func propose(_unit: Unit) -> Array[AiPlan]:
	return []
