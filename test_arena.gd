extends Node
## Combat test harness — merge this into your main scene's root script.
##
## SETUP:
##  1. Project Settings > Input Map: add three actions —
##       "test_start_combat" mapped to a key (e.g. K)
##       "test_end_turn"      mapped to a key (e.g. N)
##       "test_delay_turn"    mapped to a key (e.g. M)
##  2. Make sure your Unit instances are already in the scene tree, each
##     with `faction` set appropriately (player units default to "player";
##     give enemies something else, e.g. "enemy").
##  3. Run the scene, press the start-combat key. There's no combat UI yet,
##     so everything prints to the Output panel: turn order, whose turn it
##     is, every attack/move/death.
##  4. On your turn: right-click the ground to move (respects move budget),
##     left-click an enemy to attack (see unit.gd _on_input_event). Press
##     the end-turn key when you're done acting, or the delay-turn key to
##     give up this turn for now and go later in this same round instead
##     (see CombatManager.delay_turn — defaults to delaying by 1).

var _signals_connected: bool = false
## The raid quest's two goblinoids — see _watch_goblinoid_raid_quest().
## Emptied out as each one dies; townsperson_raids_resolved sets once
## both are gone, regardless of how the fight that killed them started.
var _goblinoids_remaining: Array[Unit] = []


## Bootstrap content, not a permanent architectural constraint — the 3
## non-leader companions are hand-placed today because that's how every
## unit in this project has been authored so far, not because
## PartyManager.members requires it. A future debug add/remove menu can
## add to (or remove from) this same roster at runtime without needing a
## party member to have ever been placed in this scene at all — see
## _build_leader() below, which already proves that shape for real.
func _ready() -> void:
	# The actual "entering the game world" moment — see MusicManager.
	# start_exploration_theme()'s own doc comment for why this call lives
	# here now instead of firing unconditionally from MusicManager's own
	# _ready() (main_menu/character_creation load first and aren't the
	# game world at all).
	MusicManager.start_exploration_theme()

	print(SkillCalculator.get_skill_level($ElfRanger, "Acrobatics").skill_level)
	_watch_goblinoid_raid_quest()

	# Bootstrap-only: on a genuinely fresh load (nothing captured from a
	# prior world), this scene builds the starting roster from its own
	# hand-placed content, same as before WorldManager existed. On a
	# RELOAD of this same scene, WorldManager is about to spawn_party() a
	# captured roster the instant this _ready() returns (spawn_party()
	# needs this scene already in the tree, so it can't run any earlier)
	# — is_restoring_party() is what lets this scene tell the difference.
	# The 4 hand-placed party nodes below are a ONE-TIME bootstrap, not
	# permanent scene content: on a reload they'd otherwise sit in the
	# tree as unregistered duplicates of whatever spawn_party() is about
	# to create from the captured data, so they're freed instead.
	if WorldManager.is_restoring_party():
		$TieflingWizard.queue_free()
		$HumanBarbarian.queue_free()
		$DwarfFighter.queue_free()
		$ElfRanger.queue_free()
	else:
		var leader: Unit = _build_leader()
		PartyManager.add_member(leader)
		PartyManager.add_member($HumanBarbarian)
		PartyManager.add_member($DwarfFighter)
		PartyManager.add_member($ElfRanger)
		PartyManager.set_leader(leader)


## Returns the real leader Unit for this session — deliberately NOT the
## same thing as "reuse whatever's already hand-placed in the scene."
## If a character was actually created (see PartyManager.pending_leader,
## written by character_creation.gd on Confirm), this spawns a genuinely
## FRESH unit via PartyManager.spawn_member() (the same instantiate-and-
## cascade path a full world reload uses — see PartyManager's own capture/
## spawn header) and frees the hand-placed TieflingWizard node outright —
## she was only ever a bootstrap placeholder standing in for "the
## leader," never a specific story character, so keeping her around
## unused once a real one exists would just be a second, silent unit
## nobody asked for.
##
## Falls back to the hand-placed TieflingWizard, completely untouched,
## if chargen was never run (loading straight into this scene for a
## headless test, e.g.) — that fallback has to keep working exactly as
## it did before this existed.
func _build_leader() -> Unit:
	var placeholder: Unit = $TieflingWizard

	if not PartyManager.pending_leader:
		return placeholder

	var leader: Unit = PartyManager.spawn_member(PartyManager.pending_leader, self, placeholder)
	placeholder.queue_free()
	PartyManager.pending_leader = null
	return leader


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("test_start_combat"):
		_start_test_combat()
	elif event.is_action_pressed("test_end_turn"):
		if CombatManager.in_combat:
			CombatManager.end_turn()
	elif event.is_action_pressed("test_delay_turn"):
		if CombatManager.in_combat:
			var unit: Unit = CombatManager.current_unit
			if unit and not CombatManager.delay_turn(unit):
				print("Couldn't delay ", unit.get_display_name(), "'s turn.")


func _start_test_combat() -> void:
	if CombatManager.in_combat:
		print("Combat already in progress.")
		return

	var units: Array[Unit] = UnitQuery.living_units(get_tree())

	if units.is_empty():
		print("No units found in the 'units' group — nothing to fight with.")
		return

	_connect_debug_signals(units)
	CombatManager.start_combat(units)


func _connect_debug_signals(units: Array[Unit]) -> void:
	if not _signals_connected:
		CombatManager.combat_started.connect(_on_combat_started)
		CombatManager.turn_started.connect(_on_turn_started)
		CombatManager.combat_ended.connect(_on_combat_ended)
		_signals_connected = true

	for unit in units:
		if not unit.ability_used.is_connected(_on_unit_ability_used):
			unit.ability_used.connect(_on_unit_ability_used)
		if not unit.died.is_connected(_on_unit_died):
			unit.died.connect(_on_unit_died)


func _on_combat_started(turn_order: Array[Unit]) -> void:
	print("--- Combat started ---")
	for unit in turn_order:
		print("  ", unit.get_display_name(), " (", unit.faction, ") DX ", unit.get_stat("DX"), " HP ", unit.current_hp)


func _on_turn_started(unit: Unit) -> void:
	var status_note: String = " — CANNOT ACT (status effect)" if unit.status_prevents_turn() else ""
	print("-> ", unit.get_display_name(), "'s turn (move budget ", unit.move_remaining, ")", status_note)
	# Auto-select the acting unit so a right-click moves it and a left-click
	# on an enemy attacks it, without manually clicking it first each turn.
	SelectionManager.select(unit)


func _on_unit_ability_used(attacker: Unit, target, result: Dictionary) -> void:
	var target_desc: String = target.get_display_name() if target is Unit else str(target)

	if result.already_acted:
		print("   ", attacker.get_display_name(), " has already acted this turn.")
	elif not result.in_range:
		print("   ", attacker.get_display_name(), " is out of range of ", target_desc, " with ", result.ability.ability_name)
	elif result.ability.requires_to_hit and not result.to_hit.success:
		print("   ", attacker.get_display_name(), " misses ", target_desc, " with ", result.ability.ability_name,
				" (rolled ", result.to_hit.roll, " vs ", result.to_hit.target, ")")
	elif target is Unit:
		print("   ", attacker.get_display_name(), " hits ", target_desc, " with ", result.ability.ability_name,
				" for ", result.damage, " damage (", target.current_hp, " HP left)")
	else:
		print("   ", attacker.get_display_name(), " uses ", result.ability.ability_name, " at ", target_desc)


func _on_unit_died(unit: Unit) -> void:
	print("   ", unit.get_display_name(), " has died.")


## Connected unconditionally at scene start, NOT through
## _connect_debug_signals above — that only wires up when combat starts
## via the K-key test harness, so it'd silently never fire for combat
## triggered the real way (clicking the hostile unit directly). The
## Scared Townperson's second dialogue phase (see her dialogue_options /
## resolved_hub.tres) depends on this flag actually getting set in a
## normal playthrough, not just the debug path.
func _watch_goblinoid_raid_quest() -> void:
	_goblinoids_remaining = [$GoblinRogue as Unit, $Hobgoblin as Unit]
	for goblinoid in _goblinoids_remaining:
		goblinoid.died.connect(_on_goblinoid_died)


func _on_goblinoid_died(unit: Unit) -> void:
	_goblinoids_remaining.erase(unit)
	if _goblinoids_remaining.is_empty():
		FlagManager.set_flag("townsperson_raids_resolved")


func _on_combat_ended(winning_faction: StringName) -> void:
	if winning_faction == &"":
		print("--- Combat ended: mutual wipe, no survivors ---")
	else:
		print("--- Combat ended: ", winning_faction, " wins ---")


## Satisfies WorldManager's duck-typed load/unload contract (see
## systems/world_system/world_manager.gd) — called on load/unload to
## register/unregister this arena's own tactical camera with
## CameraDirector.
func get_tactical_camera() -> Camera3D:
	return $Camera3D


## Duck-typed — see WorldManager.load_world()/GameMode.set_base_mode().
func get_base_mode() -> GameMode.Mode:
	return GameMode.Mode.EXPLORATION


## Satisfies WorldManager's duck-typed spawn-point contract (see
## world_manager.gd's own _resolve_spawn_point()). Only one named point
## exists today — a single starting area, the same one the hand-placed
## TieflingWizard/companions already occupy — so spawn_point_name is
## unused for now; a second world (an overworld, the fusion room) with
## multiple real entrances is what would make branching on it worthwhile.
func get_spawn_point(_spawn_point_name: StringName) -> Node3D:
	return $PartySpawnPoint
