extends UIScreen
## blocks_input_below=true is authored on this scene's instance in
## MainRoot.tscn — see UIScreen's own header. hides_hud/closes_on_cancel
## stay at their defaults (false, true): the pause menu doesn't hide the
## gameplay HUD today, and Escape closes it like any other screen.
##
## Built inline directly in MainRoot.tscn (CanvasLayer/EscMenu), not as
## its own reusable .tscn — the standalone res://esc_menu.tscn at the
## project root is orphaned, leftover content pointing at a script path
## (res://src/esc_menu.gd) that doesn't exist; nothing in the running
## game references it. Left alone as out of scope for whatever touched
## this file next — flagging here so it isn't mistaken for live content.

@onready var _debug_exit_button: Button = %DebugExitToOverworldButton


func _ready() -> void:
	visible = false
	add_to_group("esc_menu")
	_debug_exit_button.pressed.connect(_on_debug_exit_pressed)
	# GameMode can change between one menu-open and the next (combat
	# starting/ending while a player alt-tabs, e.g.) — recompute every
	# time this becomes visible rather than once at _ready(), the same
	# idiom conversation_log.gd already uses for its own on-show refresh.
	visibility_changed.connect(_on_visibility_changed)


func _on_visibility_changed() -> void:
	if visible:
		_debug_exit_button.visible = OS.is_debug_build() and GameMode.current_mode() == GameMode.Mode.EXPLORATION


func _on_exit_to_desktop_pressed() -> void:
	get_tree().quit()


func _on_exit_button_pressed() -> void:
	close()


## Debug-only escape hatch, kept alongside the real one (see
## OverworldExit/travel_interaction.gd in test_arena.tscn) — returns to
## whichever area/spawn point WorldManager.return_area_id/
## return_spawn_point currently hold, same as a real Travel exit with an
## empty target_area would. Falls back to "overworld" specifically (not
## just whatever AreaDatabase happens to find) when return_area_id is
## still empty — reachable straight from character creation, which never
## visits the overworld at all — so this debug button always works, the
## same guarantee its old hardcoded OVERWORLD_SCENE preload gave for free.
func _on_debug_exit_pressed() -> void:
	close()
	var area_id: StringName = WorldManager.return_area_id if WorldManager.return_area_id != &"" else &"overworld"
	WorldManager.load_area(area_id, WorldManager.return_spawn_point)
