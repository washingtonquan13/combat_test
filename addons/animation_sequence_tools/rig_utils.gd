@tool
extends RefCounted
## Shared "what's the shared UAL1+UAL2 rig, and what can it play" helper —
## used by animation_clip_property.gd (the Inspector dropdown) to
## enumerate clip names, and by preview_panel.gd (the live preview) to
## build the previewed model. Both need the exact same "UAL1_Standard.glb
## + UAL2_Standard.glb layered on as the UAL2_Standard library" setup
## unit.tscn's CharacterModel/AnimationPlayer has — building it in
## exactly one place means the dropdown and the preview can never
## quietly disagree about what a clip name resolves to.

const UAL1_SCENE_PATH := "res://assets/UAL1_Standard.glb"
const UAL2_LIBRARY_PATH := "res://assets/UAL2_Standard.glb"
const UAL2_LIBRARY_NAME := &"UAL2_Standard"

static var _cached_clip_names: PackedStringArray = PackedStringArray()
static var _cache_valid: bool = false


## Instantiates a fresh copy of the shared rig with both libraries
## attached. Caller owns the returned Node — free it when done.
static func instantiate_rig() -> Node:
	var model: Node = load(UAL1_SCENE_PATH).instantiate()
	var anim_player: AnimationPlayer = model.get_node("AnimationPlayer")
	anim_player.add_animation_library(UAL2_LIBRARY_NAME, load(UAL2_LIBRARY_PATH))
	return model


## Every clip name the rig can play, in the exact form
## AnimationPlayer.has_animation()/.play() expect — cached for the editor
## session since instancing a full skinned scene on every Inspector
## redraw would be wasteful. Stale only if UAL1/UAL2 are reimported with
## new clips while the editor is open; disable/re-enable the plugin (or
## restart the editor) to refresh in that case.
static func get_all_clip_names() -> PackedStringArray:
	if not _cache_valid:
		var model: Node = instantiate_rig()
		var anim_player: AnimationPlayer = model.get_node("AnimationPlayer")
		_cached_clip_names = anim_player.get_animation_list()
		model.free()
		_cache_valid = true
	return _cached_clip_names
