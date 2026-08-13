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


func _init(p_effect: StatusEffect, p_turns_remaining: int) -> void:
	effect = p_effect
	turns_remaining = p_turns_remaining
