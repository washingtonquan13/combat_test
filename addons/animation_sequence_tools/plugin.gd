@tool
extends EditorPlugin

const AnimationClipInspectorPlugin := preload("res://addons/animation_sequence_tools/animation_clip_inspector_plugin.gd")
const PreviewPanelScene := preload("res://addons/animation_sequence_tools/preview_panel.tscn")

var _inspector_plugin: EditorInspectorPlugin
var _preview_panel: Control


func _enter_tree() -> void:
	_inspector_plugin = AnimationClipInspectorPlugin.new()
	add_inspector_plugin(_inspector_plugin)

	_preview_panel = PreviewPanelScene.instantiate()
	add_control_to_bottom_panel(_preview_panel, "Animation Sequence")


func _exit_tree() -> void:
	remove_inspector_plugin(_inspector_plugin)
	_inspector_plugin = null

	remove_control_from_bottom_panel(_preview_panel)
	_preview_panel.queue_free()
	_preview_panel = null


func _handles(object: Object) -> bool:
	return object is AnimationSequence


func _edit(object: Object) -> void:
	_preview_panel.show_sequence(object as AnimationSequence)


func _make_visible(visible: bool) -> void:
	_preview_panel.set_active(visible)
