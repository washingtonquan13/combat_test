class_name DialogueEffect
extends Resource
## Base for "what happens in the world when this choice is picked" —
## the missing consequence hook named in dialogue_system_bg3_gap_analysis.md:
## flags unblock CONDITIONAL dialogue (see FlagPrerequisite), but until
## now nothing let a choice DO anything beyond that. Same discipline as
## AbilityEffect (data and the logic that interprets it live together on
## one Resource, not a manager-side type-switch) — this is that same
## shape, just for dialogue instead of abilities.
##
## apply() is fire-and-forget (no return value) — unlike AbilityEffect,
## nothing currently needs a result dict back for logging/UI. Add one
## if a future effect actually needs to report something back to the
## overlay; not built speculatively now.

## actor is the player-controlled participant (same as DialogueChoice
## .resolve()'s own actor), target is who they're talking to. Override
## in each subclass.
func apply(_actor: Unit, _target: Unit) -> void:
	push_error("%s doesn't implement apply() yet" % get_script().resource_path)


## Presentation metadata only — a short human string for whatever this
## effect takes from the player (e.g. "-50 gold"), so a response row can
## show the price BEFORE the player commits to it. "" on the base and on
## every non-cost effect (GiveItemEffect, TriggerCombatEffect, the mood
## effects): a choice that costs health, focus, gold or an item
## currently shows nothing on the button, and the price only appears in
## the echo line AFTER it's already been paid — a fairness problem, not
## a styling one. Override in each SUBCLASS THAT TAKES SOMETHING (the
## Sacrifice* family) built from that subclass's own exported fields, so
## this can never drift from what apply() actually does — it reads the
## same numbers, it just doesn't spend them. Does not change WHEN
## effects apply or what they do.
func cost_tag() -> String:
	return ""
