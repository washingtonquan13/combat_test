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

## The debug exit's own fixed destination — WorldManager no longer
## tracks "wherever you came from" at all (see the architectural
## fix-pass writeup in project memory for why remembering it was itself
## the bug), so this button just names the overworld directly. It still
## lands on the CORRECT door rather than the overworld's bare Start
## marker: WorldManager's own back-link derivation finds whichever
## overworld door leads back to the arena and lands there — this button
## doesn't need to know or care which one that is.
const HOME_AREA: StringName = &"overworld"

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
## OverworldExit/travel_interaction.gd in test_arena.tscn).
func _on_debug_exit_pressed() -> void:
	close()
	WorldManager.load_area(HOME_AREA)
