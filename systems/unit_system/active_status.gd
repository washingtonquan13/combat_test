class_name ActiveStatus
extends RefCounted
## Runtime instance of a StatusEffect currently applied to a unit — NOT
## a Resource. A Resource is shared, reusable DATA (the StatusEffect
## itself, e.g. "Bleeding" as a concept, same object potentially applied
## to many units); this is per-application instance state (THIS unit's
## Bleeding specifically, with THIS many turns left, stacked THIS many
## times) and has no business being shared or saved as an asset.

var effect: StatusEffect
var turns_remaining: int
var stacks: int = 1
## A stopped timer never runs down — Downed, whose own rolls decide
## how it ends (DeathRollsBehavior).
var stopped: bool = false
## Part of what the unit is, not something happening to it (see
## StatusManager.add_permanent): hidden, unannounced, never saved, never
## runs out.
var permanent: bool = false
## Counts a behavior keeps for this one application — Downed's marks
## toward stable and toward death.
var tally: Dictionary = {}


func _init(p_effect: StatusEffect, p_turns_remaining: int) -> void:
	effect = p_effect
	turns_remaining = p_turns_remaining
