extends Node
## Autoload singleton. Register as "DebugSpawner" under Project > Project
## Settings > AutoLoad.
##
## Tracks which UnitDefinition + faction is currently "armed" for the
## debug spawn panel's click-to-place flow (see debug_spawn_panel.gd) —
## same "arm now, resolve on the next click" shape as AbilityManager,
## deliberately kept fully separate from it: a debug spawn has no
## caster, no turn-economy cost, and must work whether or not combat is
## even running, none of which AbilityManager's model assumes.
##
## Debug-only by construction, not by a guard here — armed_definition
## can only ever be set by DebugSpawnPanel, itself gated end-to-end on
## OS.is_debug_build(). Nothing here re-checks that, same as
## AbilityManager doesn't re-check who's allowed to arm it.

signal armed_changed(definition: UnitDefinition, faction: StringName)

var armed_definition: UnitDefinition = null
var armed_faction: StringName = &"enemy"


func arm(definition: UnitDefinition, faction: StringName) -> void:
	armed_definition = definition
	armed_faction = faction
	armed_changed.emit(definition, faction)


func disarm() -> void:
	if armed_definition == null:
		return
	armed_definition = null
	armed_changed.emit(null, armed_faction)
