class_name GameOverScreen
extends UIScreen
## Shown when nobody in the party is left standing (PartyManager.defeated).
##
## Retry loads the autosave taken as the last fight started; Load last
## save loads the newest save that is not that one, so the two never
## offer the same file. Either is hidden when there is nothing to load.
##
## hides_hud, blocks_input_below and closes_on_cancel=false are authored
## on this scene's instance in MainRoot.tscn, like the main menu's.

## Set via node_paths on this scene's MainRoot.tscn instance, the same
## borrowed sibling the esc menu and main menu use.
@export var save_load_panel: SaveLoadPanel

@onready var _retry_button: Button = %RetryButton
@onready var _last_save_button: Button = %LastSaveButton
@onready var _load_button: Button = %LoadButton
@onready var _main_menu_button: Button = %MainMenuButton

## A load rebuilds the party member by member, and a half-rebuilt party
## can read as defeated for a moment. Nothing that happens during one is
## a loss.
var _loading: bool = false


func _ready() -> void:
	visible = false
	add_to_group("game_over")
	PartyManager.defeated.connect(_on_party_defeated)
	SaveManager.load_started.connect(func(_path): _loading = true)
	SaveManager.load_finished.connect(func(_path, _ok, _reason): _loading = false)
	SaveManager.load_completed.connect(_on_load_completed)
	_retry_button.pressed.connect(_load.bind(SaveManager.FIGHT_AUTOSAVE, true))
	_last_save_button.pressed.connect(_load.bind(SaveManager.FIGHT_AUTOSAVE, false))
	_load_button.pressed.connect(func(): save_load_panel.open_for(SaveLoadPanel.Mode.LOAD))
	_main_menu_button.pressed.connect(_on_main_menu_pressed)


func _on_party_defeated() -> void:
	if _loading or UIStack.is_open(self) or WorldManager.current_area() == null:
		return
	_end_party_fights()
	_refresh()
	# Behind the black so the screen fades in rather than snapping. A fade
	# already running (a defeat during travel) refuses this one, so it is
	# opened after either way.
	await WorldManager.behind_black(open)
	if not UIStack.is_open(self):
		open()


## The fight is lost, so it ends now rather than playing on under the
## screen. Won by whoever is still standing on the other side.
func _end_party_fights() -> void:
	for encounter in CombatManager.all_encounters():
		if not is_instance_valid(encounter) or not encounter.is_running:
			continue
		var winner: StringName = &""
		var has_party: bool = false
		for unit in encounter.turn_order:
			if not is_instance_valid(unit):
				continue
			if unit.is_player_controlled():
				has_party = true
			elif winner == &"" and unit.is_alive() and not unit.is_downed():
				winner = unit.faction
		if has_party:
			CombatManager.end_combat(winner, encounter)


func _refresh() -> void:
	_retry_button.visible = SaveManager.slot_path(SaveManager.FIGHT_AUTOSAVE) != ""
	_last_save_button.visible = SaveManager.most_recent_except(SaveManager.FIGHT_AUTOSAVE) != ""


## retry: the fight autosave itself. Otherwise the newest save that is
## not it.
func _load(slot: String, retry: bool) -> void:
	var path: String = SaveManager.slot_path(slot) if retry else SaveManager.most_recent_except(slot)
	if path != "":
		WorldManager.behind_black(SaveManager.load_file.bind(path))


## The esc menu's exit, without its can_travel() question: the fight was
## ended above, and nothing on this screen is worth keeping.
func _on_main_menu_pressed() -> void:
	WorldManager.behind_black(func() -> void:
		if not WorldManager.unload():
			return
		close()
		UIStack.push(get_tree().get_first_node_in_group("main_menu")))


func _on_load_completed(_path: String) -> void:
	if UIStack.is_open(self):
		close()
