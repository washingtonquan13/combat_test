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
## nothing currently needs a result dict back for logging/UI. An effect
## that has something to say records it into the conversation instead.

## c is the conversation the choice was picked in: c.cast.player is the
## player-controlled participant, c.cast.npc who they're talking to, and
## c.vars this conversation's own variables. Override in each subclass.
func apply(_c: Conversation) -> void:
	push_error("%s doesn't implement apply() yet" % get_script().resource_path)


## Presentation metadata only — a short human string for whatever this
## effect takes from the player (e.g. "-50 gold"), so a response row can
## show the price BEFORE the player commits to it. "" on the base and on
## every non-cost effect (GiveItemEffect, TriggerCombatEffect, the mood
## effects): without it a choice that costs health, focus, gold or an item
## would show nothing on the row, and the price would only appear AFTER
## it's already been paid — a fairness problem, not a styling one.
## Override in each SUBCLASS THAT TAKES SOMETHING (the Sacrifice* family)
## built from that subclass's own exported fields, so this can never drift
## from what apply() actually does — it reads the same numbers, it just
## doesn't spend them. c is passed so a cost read from a conversation
## variable (see SacrificeNegotiatedGoldEffect) previews the same number it
## will spend.
func cost_tag(_c: Conversation) -> String:
	return ""


## True for an effect that is a tree's explicit ending — what a strict lint
## (see Conversations.lint) accepts in place of a next id. Lint metadata
## only: whether the conversation actually ends is still up to apply().
func ends_conversation() -> bool:
	return false


## What is wrong with how this effect was authored, or "" — reported by
## Conversations.lint at load, so a mistake an effect can only recover from
## quietly at runtime (an outcome left unset, say) is still seen.
func authoring_problem() -> String:
	return ""
