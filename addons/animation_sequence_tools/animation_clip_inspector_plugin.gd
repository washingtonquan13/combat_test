@tool
extends EditorInspectorPlugin
## Swaps the default free-text editor for a validated dropdown (see
## animation_clip_property.gd) on any String property that holds an
## AnimationPlayer clip name — matched by name pattern rather than by
## object type, since that same "String meant to hold a clip name" shape
## shows up on AnimationPhase (animation_name), StatusEffect
## (apply_animation/remove_animation/hit_reaction_animation), Ability
## (armed_enter_animation/armed_hold_animation), and UnitAnimator
## (idle_animation/walk_animation/hit_animation/death_animation/
## default_armed_enter_animation/default_armed_hold_animation) —
## confirmed to be the full, exhaustive list project-wide via
## `grep '@export var \w*animation\w*\s*:\s*String'`, zero false
## positives. A name-pattern match also means this fires uniformly
## whether the inspected object is a Resource or a Node (e.g. selecting
## the UnitAnimator node directly in unit.tscn's scene tree) — the
## EditorInspectorPlugin API doesn't distinguish the two.

const AnimationClipProperty := preload("res://addons/animation_sequence_tools/animation_clip_property.gd")


func _can_handle(_object: Object) -> bool:
	return true  # filtering happens in _parse_property by name+type, not by object type


func _parse_property(_object: Object, type: Variant.Type, name: String, _hint_type: PropertyHint, _hint_string: String, _usage_flags: int, _wide: bool) -> bool:
	if type != TYPE_STRING:
		return false
	if name != "animation_name" and not name.ends_with("_animation"):
		return false
	add_property_editor(name, AnimationClipProperty.new())
	return true
