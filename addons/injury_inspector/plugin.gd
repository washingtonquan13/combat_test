@tool
extends EditorPlugin

const InjuryInspector := preload("res://addons/injury_inspector/injury_inspector.gd")

var _inspector_plugin: EditorInspectorPlugin


func _enter_tree() -> void:
	_inspector_plugin = InjuryInspector.new()
	add_inspector_plugin(_inspector_plugin)


func _exit_tree() -> void:
	remove_inspector_plugin(_inspector_plugin)
	_inspector_plugin = null
