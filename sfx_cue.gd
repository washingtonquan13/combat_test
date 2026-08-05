class_name SfxCue
extends Resource
## A composable set of sounds for ONE moment (armed-enter, launch,
## impact) — see SfxLayer for why this exists instead of a bare
## AudioStream field: layering multiple sounds, staggered timing,
## per-layer volume/pitch, without needing a full awaited step sequence
## the way VfxEffect requires (SFX never needs to block anything, so
## there's no equivalent need for true sequential dependencies between
## layers — see unit_sfx.gd's header for the non-blocking principle
## this whole system is built around).
##
## Create instances as .tres files, assign one or more SfxLayer
## resources to layers. Assign the result to an Ability's
## armed_enter_sfx/launch_sfx/impact_sfx field.

@export var layers: Array[SfxLayer] = []


func play(context: Node, position: Vector3) -> void:
	for layer in layers:
		if layer:
			layer.play(context, position)
